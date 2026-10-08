#!/usr/bin/env python3
"""CI-only full-test supervisor. Never records command lines or environment.

Windows starts the child suspended, assigns a private kill-on-close Job Object,
then resumes its sole initial thread. Metadata and cleanup use that job, rather
than treating an old/reused numeric PID as ownership. Native proof is required.
"""
from __future__ import annotations
import argparse
import ctypes
import datetime
import json
import ntpath
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


class WindowsJob:
    def __init__(self):
        from ctypes import wintypes as w
        self.w = w
        k = self.k = ctypes.WinDLL('kernel32', use_last_error=True)
        signatures = {
            'CreateJobObjectW': ([ctypes.c_void_p, w.LPCWSTR], w.HANDLE),
            'SetInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD], w.BOOL),
            'AssignProcessToJobObject': ([w.HANDLE, w.HANDLE], w.BOOL),
            'QueryInformationJobObject': ([w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.c_void_p], w.BOOL),
            'TerminateJobObject': ([w.HANDLE, w.UINT], w.BOOL),
            'CloseHandle': ([w.HANDLE], w.BOOL),
            'OpenProcess': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'IsProcessInJob': ([w.HANDLE, w.HANDLE, ctypes.POINTER(w.BOOL)], w.BOOL),
            'QueryFullProcessImageNameW': ([w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)], w.BOOL),
            'GetProcessTimes': ([w.HANDLE, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p], w.BOOL),
            'CreateToolhelp32Snapshot': ([w.DWORD, w.DWORD], w.HANDLE),
            'Thread32First': ([w.HANDLE, ctypes.c_void_p], w.BOOL),
            'Thread32Next': ([w.HANDLE, ctypes.c_void_p], w.BOOL),
            'OpenThread': ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            'GetProcessIdOfThread': ([w.HANDLE], w.DWORD),
            'ResumeThread': ([w.HANDLE], w.DWORD),
        }
        for name, (args, result) in signatures.items():
            getattr(k, name).argtypes = args
            getattr(k, name).restype = result

        class BasicLimit(ctypes.Structure):
            _fields_ = [('perProcessTime', ctypes.c_int64), ('perJobTime', ctypes.c_int64),
                        ('flags', w.DWORD), ('minWorkingSet', ctypes.c_size_t),
                        ('maxWorkingSet', ctypes.c_size_t), ('activeProcessLimit', w.DWORD),
                        ('affinity', ctypes.c_size_t), ('priorityClass', w.DWORD),
                        ('schedulingClass', w.DWORD)]
        class IO(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ('readCount', 'writeCount', 'otherCount', 'readBytes', 'writeBytes', 'otherBytes')]
        class ExtendedLimit(ctypes.Structure):
            _fields_ = [('basic', BasicLimit), ('io', IO), ('processMemory', ctypes.c_size_t),
                        ('jobMemory', ctypes.c_size_t), ('peakProcessMemory', ctypes.c_size_t),
                        ('peakJobMemory', ctypes.c_size_t)]
        self.root_identity = None
        self.handle = k.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimit()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE; no breakaway flags.
        if not k.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)

    def assign_and_resume(self, process):
        # Python 3.12 on this CI host retains the process HANDLE. The suspended
        # process cannot create children before assignment to our private job.
        if not self.k.AssignProcessToJobObject(self.handle, int(process._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        created, exited, kernel, user = (ctypes.c_uint64() for _ in range(4))
        if not self.k.GetProcessTimes(int(process._handle), *(ctypes.byref(v) for v in (created, exited, kernel, user))):
            raise ctypes.WinError(ctypes.get_last_error())
        self.root_identity = (process.pid, created.value)
        w = self.w
        class ThreadEntry(ctypes.Structure):
            _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('tid', w.DWORD),
                        ('owner', w.DWORD), ('basePriority', w.LONG),
                        ('deltaPriority', w.LONG), ('flags', w.DWORD)]
        snap = self.k.CreateToolhelp32Snapshot(4, 0)  # TH32CS_SNAPTHREAD
        if snap == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        ids = []
        entry = ThreadEntry()
        entry.size = ctypes.sizeof(entry)
        try:
            found = self.k.Thread32First(snap, ctypes.byref(entry))
            while found:
                if entry.owner == process.pid:
                    ids.append(entry.tid)
                entry.size = ctypes.sizeof(entry)
                found = self.k.Thread32Next(snap, ctypes.byref(entry))
        finally:
            self.k.CloseHandle(snap)
        if len(ids) != 1 or process.poll() is not None:
            raise RuntimeError('suspended_child_thread_unavailable')
        thread = self.k.OpenThread(0x0002 | 0x0040, False, ids[0])
        if not thread:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if self.k.GetProcessIdOfThread(thread) != process.pid:
                raise RuntimeError('suspended_child_thread_identity_changed')
            if self.k.ResumeThread(thread) != 1:
                raise RuntimeError('suspended_child_resume_failed')
        finally:
            self.k.CloseHandle(thread)

    def snapshot(self, root_pid):
        width = ctypes.sizeof(ctypes.c_size_t)
        for capacity in (64, 256, 1024, 4096):
            buf = ctypes.create_string_buffer(8 + width * capacity)
            if self.k.QueryInformationJobObject(self.handle, 3, buf, len(buf), None):
                count = ctypes.c_uint32.from_buffer(buf, 4).value
                if count > capacity:
                    raise RuntimeError('invalid_job_process_count')
                ids = (ctypes.c_size_t * count).from_buffer(buf, 8)
                break
            if ctypes.get_last_error() != 234:  # ERROR_MORE_DATA
                raise ctypes.WinError(ctypes.get_last_error())
        else:
            raise RuntimeError('job_process_snapshot_exceeds_bound')
        rows = []
        for pid in ids:
            handle = self.k.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED_INFORMATION
            if not handle:
                continue  # Process may have exited since the job snapshot.
            try:
                belongs = self.w.BOOL()
                if not self.k.IsProcessInJob(handle, self.handle, ctypes.byref(belongs)) or not belongs:
                    continue  # A reused PID outside this job is never retained or terminated.
                created, exited, kernel, user = (ctypes.c_uint64() for _ in range(4))
                if not self.k.GetProcessTimes(handle, *(ctypes.byref(v) for v in (created, exited, kernel, user))):
                    continue
                size = self.w.DWORD(32768)
                name = ctypes.create_unicode_buffer(size.value)
                image = 'unavailable'
                if self.k.QueryFullProcessImageNameW(handle, 0, name, ctypes.byref(size)):
                    image = ntpath.basename(name.value)
                rows.append({'pid': int(pid), 'root': (int(pid), created.value) == self.root_identity, 'imageName': image,
                             'creationFileTime100ns': created.value,
                             'kernelTime100ns': kernel.value, 'userTime100ns': user.value})
            finally:
                self.k.CloseHandle(handle)
        return sorted(rows, key=lambda row: row['pid'])

    def terminate(self):
        if self.handle and not self.k.TerminateJobObject(self.handle, 124):
            raise ctypes.WinError(ctypes.get_last_error())

    def close(self):
        if self.handle:
            self.k.CloseHandle(self.handle)
            self.handle = None


def supervise(command, prefix, deadline_seconds=1440, heartbeat_seconds=10, progress=False):
    prefix = Path(prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    event_path = Path(str(prefix) + '-events.jsonl')
    phase_path = Path(str(prefix) + '-phase.json')
    log_path = Path(str(prefix) + '-output.log')
    start = time.monotonic()
    phase = {'schemaVersion': 1, 'state': 'STARTED', 'platform': sys.platform,
             'startedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
             'deadlineSeconds': deadline_seconds, 'heartbeatSeconds': heartbeat_seconds}
    process = job = None
    drain = None
    drain_done = threading.Event()
    counters = {'outputBytes': 0, 'lastOutputElapsedSeconds': None, 'drainError': None}
    lock = threading.Lock()
    events = event_path.open('w', encoding='utf-8', buffering=1)
    output = log_path.open('wb', buffering=0)

    def record(event, **fields):
        row = {'event': event, 'elapsedSeconds': round(time.monotonic() - start, 3),
               'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields}
        events.write(json.dumps(row, sort_keys=True) + '\n')
        events.flush()
        if progress:
            compact = {key: row[key] for key in ('event', 'elapsedSeconds', 'rootPID', 'outputBytes',
                       'childExitCode', 'exitCode', 'state', 'operation', 'nativeErrorCode') if key in row}
            if 'ownedProcesses' in row:
                processes = row['ownedProcesses']
                compact['ownedProcesses'] = [
                    {key: process[key] for key in ('pid', 'root', 'imageName', 'kernelTime100ns', 'userTime100ns')
                     if key in process} for process in processes[:64]]
                compact['ownedProcessCount'] = len(processes)
            print('RIGHTCLICK-CI-PROGRESS ' + json.dumps(compact, separators=(',', ':')),
                  file=sys.stderr, flush=True)

    def persist():
        temporary = Path(str(phase_path) + '.new')
        temporary.write_text(json.dumps(phase, indent=2) + '\n', encoding='utf-8')
        os.replace(temporary, phase_path)

    def snapshot():
        if job:
            return job.snapshot(process.pid)
        return [{'pid': process.pid, 'root': True, 'imageName': Path(command[0]).name,
                 'scope': 'POSIX root only; Windows descendant metadata unproved on this host'}]

    def drain_output():
        try:
            while chunk := os.read(process.stdout.fileno(), 4096):
                output.write(chunk)
                with lock:
                    counters['outputBytes'] += len(chunk)
                    counters['lastOutputElapsedSeconds'] = round(time.monotonic() - start, 3)
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
        except Exception as error:
            with lock:
                counters['drainError'] = type(error).__name__
        finally:
            drain_done.set()

    exit_code = 125
    operation = 'startup_record'
    try:
        persist()
        record('supervisor_started')
        if os.name == 'nt':
            operation = 'create_owned_job'
            job = WindowsJob()
        operation = 'launch_suspended_child' if job else 'launch_child'
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, bufsize=0,
                                   creationflags=4 if job else 0, start_new_session=not bool(job))
        phase['rootPID'] = process.pid
        record('child_created', rootPID=process.pid, suspended=bool(job))
        persist()
        if job:
            operation = 'assign_owned_job_and_resume'
            job.assign_and_resume(process)
        operation = 'monitor_owned_processes'
        record('child_launched', rootPID=process.pid, ownedProcesses=snapshot())
        persist()
        drain = threading.Thread(target=drain_output, daemon=True)
        drain.start()
        next_heartbeat = 0
        timed_out = False
        while process.poll() is None:
            elapsed = time.monotonic() - start
            if elapsed >= deadline_seconds:
                timed_out = True
                record('deadline_reached', rootPID=process.pid, ownedProcesses=snapshot())
                break
            if elapsed >= next_heartbeat:
                with lock:
                    current_output = dict(counters)
                record('heartbeat', rootPID=process.pid, ownedProcesses=snapshot(), **current_output)
                next_heartbeat = elapsed + heartbeat_seconds
            time.sleep(min(0.1, max(0.001, deadline_seconds - elapsed)))
        if not timed_out:
            record('child_exited', rootPID=process.pid, childExitCode=process.returncode,
                   ownedProcesses=snapshot())
        # Cleanup is exclusively the owned job/created session. Never taskkill a
        # PID from historical metadata, and never wait indefinitely for pipe EOF.
        operation = 'cleanup_owned_processes'
        if job:
            job.terminate()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        drain.join(timeout=5)
        with lock:
            current_output = dict(counters)
        exit_code = 124 if timed_out else process.returncode
        if not drain_done.is_set() or current_output['drainError']:
            exit_code = 125
        phase.update(state='TIMED_OUT' if timed_out else 'COMPLETED', exitCode=exit_code,
                     childExitCode=process.returncode, outputDrainCompleted=drain_done.is_set(), **current_output)
        record('owned_cleanup_completed', rootPID=process.pid, outputDrainCompleted=drain_done.is_set())
    except Exception as error:
        exit_code = 125
        phase.update(state='SUPERVISOR_FAILED', exitCode=125, errorType=type(error).__name__,
                     operation=operation, nativeErrorCode=getattr(error, 'winerror', None))
        record('supervisor_failed', errorType=type(error).__name__, operation=operation,
               nativeErrorCode=getattr(error, 'winerror', None))
    finally:
        if job:
            job.close()  # Kill-on-close also contains exceptional paths.
        if process and process.poll() is None:
            process.kill()  # Python uses the original process handle on Windows.
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        if drain:
            drain.join(timeout=1)
        phase['completedUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        phase['elapsedSeconds'] = round(time.monotonic() - start, 3)
        persist()
        record('supervisor_finished', state=phase['state'], exitCode=exit_code)
        if drain_done.is_set() or drain is None:
            output.close()
        events.close()
    return exit_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--progress', action='store_true', help='Flush compact owned-process status to stderr; no arguments/environment.')
    parser.add_argument('--deadline-seconds', type=float, default=1440)
    parser.add_argument('--heartbeat-seconds', type=float, default=10)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command or not 0 < args.deadline_seconds <= 1440 or not 0 < args.heartbeat_seconds <= 30:
        parser.error('command and bounded positive timing values are required')
    return supervise(command, args.prefix, args.deadline_seconds, args.heartbeat_seconds, args.progress)


if __name__ == '__main__':
    raise SystemExit(main())
