#!/usr/bin/env python3
"""Actual owned children validate the CI supervisor; Windows job proof is native."""
from pathlib import Path
import ctypes
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'windows_test_supervisor.py'


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='rightclick-ci-supervisor-')
        self.root = Path(self.temporary.name)
        self.prefix = self.root / 'proof'

    def tearDown(self):
        self.temporary.cleanup()

    def launch(self, code, deadline=8, extra=()):
        return subprocess.Popen([sys.executable, '-u', str(SCRIPT), '--prefix', str(self.prefix),
                                 '--deadline-seconds', str(deadline), '--heartbeat-seconds', '0.1',
                                 '--', sys.executable, '-u', '-c', code, *extra],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def run_child(self, code, deadline=8, extra=()):
        process = self.launch(code, deadline, extra)
        try:
            _, errors = process.communicate(timeout=deadline + 12)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)
            self.fail('supervisor did not enforce its owned-child deadline')
        self.assertEqual(errors, b'')
        return process.returncode

    def phase(self):
        return json.loads(Path(str(self.prefix) + '-phase.json').read_text())

    def events(self):
        return [json.loads(line) for line in Path(str(self.prefix) + '-events.jsonl').read_text().splitlines()]

    def test_nonzero_exit_is_preserved(self):
        self.assertEqual(self.run_child("import os; os.write(1,b'out'); os.write(2,b'err'); raise SystemExit(17)"), 17)
        self.assertEqual(Path(str(self.prefix) + '-output.log').read_bytes(), b'outerr')
        self.assertEqual(self.phase()['childExitCode'], 17)
        self.assertTrue(self.phase()['outputDrainCompleted'])

    def test_available_bytes_without_newline_drain_before_child_exit(self):
        process = self.launch("import os,time; os.write(1,b'no-newline'); time.sleep(3)")
        try:
            end = time.monotonic() + 2.5
            while time.monotonic() < end:
                file = Path(str(self.prefix) + '-output.log')
                if file.exists() and file.read_bytes() == b'no-newline':
                    break
                time.sleep(0.02)
            else:
                self.fail('available bytes waited for newline/child EOF')
            self.assertIsNone(process.poll())
            _, errors = process.communicate(timeout=8)
            self.assertEqual(errors, b'')
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def test_both_streams_exceed_pipe_capacity_without_waiting_first(self):
        self.assertEqual(self.run_child("import os; os.write(1,b'A'*1048576); os.write(2,b'B'*1048576)"), 0)
        self.assertEqual(Path(str(self.prefix) + '-output.log').read_bytes(), b'A'*1048576 + b'B'*1048576)
        self.assertEqual(self.phase()['outputBytes'], 2097152)

    def test_silent_child_deadline_retains_launch_timeout_and_cleanup(self):
        self.assertEqual(self.run_child('import time; time.sleep(60)', deadline=0.6), 124)
        events = [event['event'] for event in self.events()]
        for expected in ('child_launched', 'heartbeat', 'deadline_reached', 'owned_cleanup_completed', 'supervisor_finished'):
            self.assertIn(expected, events)
        self.assertEqual(self.phase()['state'], 'TIMED_OUT')
        self.assertLess(self.phase()['elapsedSeconds'], 8)

    def test_descendant_retaining_output_handle_does_not_hold_supervisor_open(self):
        code = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'], stdout=sys.stdout, stderr=sys.stderr)"
        before = time.monotonic()
        self.assertEqual(self.run_child(code), 0)
        self.assertLess(time.monotonic() - before, 8)
        self.assertTrue(self.phase()['outputDrainCompleted'])

    def test_metadata_does_not_retain_arguments_or_environment(self):
        self.assertEqual(self.run_child('pass', extra=('private-argument-sentinel',)), 0)
        for path in (Path(str(self.prefix) + '-phase.json'), Path(str(self.prefix) + '-events.jsonl')):
            text = path.read_text()
            self.assertNotIn('private-argument-sentinel', text)
            self.assertNotIn('commandLine', text)
            self.assertNotIn('environment', text)

    def test_launch_failure_is_not_a_test_pass_and_does_not_print_arguments(self):
        process = subprocess.run([sys.executable, str(SCRIPT), '--prefix', str(self.prefix), '--',
                                  str(self.root / 'absent-command'), 'private-argument-sentinel'],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertEqual(process.returncode, 125)
        self.assertEqual(self.phase()['state'], 'SUPERVISOR_FAILED')
        self.assertNotIn(b'private-argument-sentinel', process.stdout + process.stderr)

    @unittest.skipUnless(os.name == 'nt', 'Windows Job Object ownership requires a native Windows host')
    def test_native_job_retains_only_owned_root_and_descendant_and_spares_outsider(self):
        outsider = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            code = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'], stdout=sys.stdout, stderr=sys.stderr); time.sleep(60)"
            self.assertEqual(self.run_child(code, deadline=5), 124)
            rows = [row for event in self.events() for row in event.get('ownedProcesses', [])]
            self.assertTrue(any(row['root'] for row in rows))
            self.assertTrue(any(not row['root'] for row in rows))
            self.assertNotIn(outsider.pid, {row['pid'] for row in rows})
            self.assertIsNone(outsider.poll(), 'cleanup crossed the private job ownership boundary')
            # Inspect identities by handle, never terminate a retained numeric PID.
            k = ctypes.WinDLL('kernel32', use_last_error=True)
            from ctypes import wintypes as w
            k.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]; k.OpenProcess.restype = w.HANDLE
            k.GetProcessTimes.argtypes = [w.HANDLE] + [ctypes.c_void_p]*4; k.GetProcessTimes.restype = w.BOOL
            k.GetExitCodeProcess.argtypes = [w.HANDLE, ctypes.POINTER(w.DWORD)]; k.GetExitCodeProcess.restype = w.BOOL
            k.CloseHandle.argtypes = [w.HANDLE]; k.CloseHandle.restype = w.BOOL
            for row in rows:
                handle = k.OpenProcess(0x1000, False, row['pid'])
                if not handle:
                    continue
                try:
                    values = [ctypes.c_uint64() for _ in range(4)]
                    self.assertTrue(k.GetProcessTimes(handle, *(ctypes.byref(v) for v in values)))
                    if values[0].value != row['creationFileTime100ns']:
                        continue  # PID was reused; it is not this fixture process.
                    status = w.DWORD()
                    self.assertTrue(k.GetExitCodeProcess(handle, ctypes.byref(status)))
                    self.assertNotEqual(status.value, 259)
                finally:
                    k.CloseHandle(handle)
        finally:
            outsider.terminate()
            outsider.wait(timeout=5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
