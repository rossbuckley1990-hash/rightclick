#!/usr/bin/env python3
"""Acquisition-only Python matrix; private bounded streams, no inherited PATH."""
from pathlib import Path, PureWindowsPath
import argparse, ctypes, hashlib, io, json, os, re, struct, subprocess, sys, tarfile, tempfile, threading, time
from windows_test_supervisor import WindowsJob

SOURCE = '048436f791b9b5ff124582117ba2f6b0df1bae92'
SOURCES_TREE = '9716cb182db859368f47b603137189d3b257ca43'
CERT_SHA = '1f10ec5ff26b0ef1fbb91248ac954cf15757e8782101f90abe05a171af58bf9d'
INPUTS = ['Package.swift', 'Package.resolved', 'LICENSE', 'Sources', 'Tests', 'Vendor', 'fixtures', 'packaging', 'scripts']
QUERY_ARGS = ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']
PROFILES = ('minimal_before', 'fixed_system_executable_search', 'machine_application_data', 'machine_data_and_system_search', 'minimal_after')
RAW_NAMES = {'query-stdout.log', 'query-stderr.log'} | {f'{renderer}-{i}-{stream}.log' for renderer in ('packed', 'owned') for i in range(5) for stream in ('stdout', 'stderr')}
MAX_STDOUT, MAX_STDERR = 16_384, 32_768


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unsafe_path(path):
    path = path.absolute()
    return any(p.is_symlink() or getattr(p, 'is_junction', lambda: False)() for p in (path, *path.parents))


def host_path(value, search=False):
    if (not isinstance(value, str) or not 0 < len(value.encode('utf-8')) <= 4096
            or len(value.encode('utf-16-le')) // 2 > 4096
            or not re.match(r'^[A-Za-z]:[\\/]', value) or not PureWindowsPath(value).is_absolute()
            or any(ord(c) < 32 or c == '"' for c in value) or ':' in value[2:]
            or any(p in ('', '.', '..') or p.endswith(('.', ' ')) for p in re.split(r'[\\/]', value[3:]))
            or (search and ';' in value)):
        raise ValueError('host_path')
    return value


def selected_host_context(environment):
    # Windows os.environ performs case-insensitive lookup. Never enumerate it.
    return {name: environment.get(name) for name in ('SystemRoot', 'ProgramData', 'ProgramFiles(x86)')}


def profiles(selected, temporary):
    if set(selected) != {'SystemRoot', 'ProgramData', 'ProgramFiles(x86)'}:
        raise ValueError('fixed_parent_lookup')
    system = host_path(selected['SystemRoot'], search=True)
    machine = host_path(selected['ProgramData'])
    minimum = {'SystemRoot': system, 'TEMP': host_path(temporary), 'TMP': host_path(temporary)}
    # One absolute directory derived from a fixed host root, never ambient PATH.
    search = host_path(str(PureWindowsPath(system) / 'System32'), search=True)
    return [minimum, {**minimum, 'PATH': search}, {**minimum, 'ProgramData': machine},
            {**minimum, 'PATH': search, 'ProgramData': machine}, minimum]


def private_object(path, directory, data=b'', read_only=False):
    """Create atomically and read back the current user's protected sole ACE."""
    from ctypes import wintypes as w
    k, a = ctypes.WinDLL('kernel32', use_last_error=True), ctypes.WinDLL('advapi32', use_last_error=True)
    k.GetCurrentProcess.argtypes, k.GetCurrentProcess.restype = [], w.HANDLE
    k.CloseHandle.argtypes, k.CloseHandle.restype = [w.HANDLE], w.BOOL
    k.LocalFree.argtypes, k.LocalFree.restype = [ctypes.c_void_p], ctypes.c_void_p
    a.OpenProcessToken.argtypes, a.OpenProcessToken.restype = [w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)], w.BOOL
    a.GetTokenInformation.argtypes, a.GetTokenInformation.restype = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD)], w.BOOL
    a.ConvertSidToStringSidW.argtypes, a.ConvertSidToStringSidW.restype = [ctypes.c_void_p, ctypes.POINTER(w.LPWSTR)], w.BOOL
    a.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [w.LPCWSTR, w.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(w.DWORD)]
    a.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = w.BOOL
    class TokenUser(ctypes.Structure):
        _fields_ = [('sid', ctypes.c_void_p), ('attributes', w.DWORD)]
    class SecurityAttributes(ctypes.Structure):
        _fields_ = [('length', w.DWORD), ('descriptor', ctypes.c_void_p), ('inheritHandle', w.BOOL)]
    k.CreateDirectoryW.argtypes, k.CreateDirectoryW.restype = [w.LPCWSTR, ctypes.POINTER(SecurityAttributes)], w.BOOL
    k.CreateFileW.argtypes, k.CreateFileW.restype = [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.POINTER(SecurityAttributes), w.DWORD, w.DWORD, w.HANDLE], w.HANDLE
    k.WriteFile.argtypes, k.WriteFile.restype = [w.HANDLE, ctypes.c_void_p, w.DWORD, ctypes.POINTER(w.DWORD), ctypes.c_void_p], w.BOOL
    k.SetFileAttributesW.argtypes, k.SetFileAttributesW.restype = [w.LPCWSTR, w.DWORD], w.BOOL
    token, sid_text, descriptor = w.HANDLE(), w.LPWSTR(), ctypes.c_void_p()
    file_handle = None
    try:
        if not a.OpenProcessToken(k.GetCurrentProcess(), 8, ctypes.byref(token)):
            raise ValueError('private_token')
        size = w.DWORD()
        a.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))
        if not 0 < size.value <= 4096:
            raise ValueError('private_token_budget')
        token_buffer = ctypes.create_string_buffer(size.value)
        if not a.GetTokenInformation(token, 1, token_buffer, size, ctypes.byref(size)):
            raise ValueError('private_token')
        sid = TokenUser.from_buffer(token_buffer).sid
        if not a.ConvertSidToStringSidW(sid, ctypes.byref(sid_text)):
            raise ValueError('private_sid')
        value = sid_text.value
        if not isinstance(value, str) or not re.fullmatch(r'S-1-(?:[0-9]{1,10}-){1,14}[0-9]{1,10}', value):
            raise ValueError('private_sid_shape')
        flags = 'OICI' if directory else ''
        if not a.ConvertStringSecurityDescriptorToSecurityDescriptorW('O:' + value + 'D:P(A;' + flags + ';FA;;;' + value + ')', 1, ctypes.byref(descriptor), None):
            raise ValueError('private_acl')
        attrs = SecurityAttributes(ctypes.sizeof(SecurityAttributes), descriptor, False)
        host_path(str(path.absolute()))
        if unsafe_path(path) or path.exists(): raise ValueError('private_object')
        if directory:
            if not k.CreateDirectoryW(str(path.absolute()), ctypes.byref(attrs)): raise ValueError('private_directory')
        else:
            if not isinstance(data, bytes) or len(data) > 65_536: raise ValueError('private_file_budget')
            file_handle = k.CreateFileW(str(path.absolute()), 0x40020000, 0, ctypes.byref(attrs), 1, 0x00200080, None)
            if not file_handle or file_handle == ctypes.c_void_p(-1).value:
                file_handle = None; raise ValueError('private_file')
        # Verify effective ownership and the protected single owner-only ACE
        # before any child stream or source/header data can be captured here.
        a.GetNamedSecurityInfoW.argtypes = [w.LPWSTR, ctypes.c_int, w.DWORD,
            ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        a.GetNamedSecurityInfoW.restype = w.DWORD
        a.GetSecurityInfo.argtypes = [w.HANDLE, ctypes.c_int, w.DWORD,
            ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]
        a.GetSecurityInfo.restype = w.DWORD
        a.GetSecurityDescriptorControl.argtypes = [ctypes.c_void_p, ctypes.POINTER(w.WORD), ctypes.POINTER(w.DWORD)]
        a.GetSecurityDescriptorControl.restype = w.BOOL
        a.GetAce.argtypes, a.GetAce.restype = [ctypes.c_void_p, w.DWORD, ctypes.POINTER(ctypes.c_void_p)], w.BOOL
        a.EqualSid.argtypes, a.EqualSid.restype = [ctypes.c_void_p, ctypes.c_void_p], w.BOOL
        class ACL(ctypes.Structure):
            _fields_ = [('revision', w.BYTE), ('reserved', w.BYTE), ('size', w.WORD), ('count', w.WORD), ('reserved2', w.WORD)]
        class ACE(ctypes.Structure):
            _fields_ = [('type', w.BYTE), ('flags', w.BYTE), ('size', w.WORD), ('mask', w.DWORD)]
        effective, owner, acl, ace = (ctypes.c_void_p() for _ in range(4))
        try:
            first = (str(path.absolute()), a.GetNamedSecurityInfoW) if directory else (file_handle, a.GetSecurityInfo)
            if first[1](first[0], 1, 1 | 4, ctypes.byref(owner), None,
                    ctypes.byref(acl), None, ctypes.byref(effective)) != 0:
                raise ValueError('private_acl_readback')
            control, revision = w.WORD(), w.DWORD()
            if (not a.GetSecurityDescriptorControl(effective, ctypes.byref(control), ctypes.byref(revision))
                    or not control.value & 0x1000 or not owner or not acl
                    or not a.EqualSid(owner, sid) or ACL.from_address(acl.value).count != 1
                    or not a.GetAce(acl, 0, ctypes.byref(ace))):
                raise ValueError('private_acl_readback')
            entry = ACE.from_address(ace.value)
            if entry.type != 0 or entry.flags != (3 if directory else 0) or entry.mask != 0x1f01ff or not a.EqualSid(ace.value + 8, sid):
                raise ValueError('private_acl_readback')
        finally:
            if effective: k.LocalFree(effective)
        if file_handle:
            buffer, count = ctypes.create_string_buffer(data), w.DWORD()
            if not k.WriteFile(file_handle, buffer, len(data), ctypes.byref(count), None) or count.value != len(data): raise ValueError('private_file_write')
            if not k.CloseHandle(file_handle): raise ValueError('private_file_close')
            file_handle = None
        if read_only and not k.SetFileAttributesW(str(path.absolute()), 1): raise ValueError('private_read_only')
    finally:
        if file_handle: k.CloseHandle(file_handle)
        if descriptor: k.LocalFree(descriptor)
        if sid_text: k.LocalFree(ctypes.cast(sid_text, ctypes.c_void_p))
        if token: k.CloseHandle(token)


def private_directory(path):
    private_object(path, True)


def private_file(path, data, read_only=False):
    private_object(path, False, data, read_only)


def active_processes(job):
    from ctypes import wintypes as w
    class Accounting(ctypes.Structure):
        _fields_ = [('user', ctypes.c_int64), ('kernel', ctypes.c_int64),
                    ('periodUser', ctypes.c_int64), ('periodKernel', ctypes.c_int64),
                    ('faults', w.DWORD), ('total', w.DWORD), ('active', w.DWORD), ('terminated', w.DWORD)]
    info = Accounting()
    if not job.k.QueryInformationJobObject(job.handle, 1, ctypes.byref(info), ctypes.sizeof(info), None):
        raise ValueError('owned_job_accounting')
    return info.active


def observe_quiescence(job, deadline, query=active_processes, now=time.monotonic, pause=time.sleep):
    """Observe this owned job within the original child deadline, never cleanup."""
    began = now()
    initial = current = query(job)
    observed = now()
    polls = 1
    while current != 0 and observed < deadline:
        pause(min(0.002, deadline - observed))
        current = query(job)
        observed = now(); polls += 1
    return {'initialOwnedActiveProcesses': initial, 'finalOwnedActiveProcesses': current,
            'ownedQuiescenceWaitMilliseconds': round((observed - began) * 1000, 3),
            'postParentRemainingBudgetMilliseconds': round(max(0, deadline - began) * 1000, 3),
            'ownedQuiescencePolls': polls,
            'ownedQuiescenceObservedBeforeDeadline': current == 0 and observed <= deadline}


class BoundedStream:
    def __init__(self, maximum):
        self.maximum, self.data, self.observed = maximum, bytearray(), 0
        self.over, self.error, self.done = False, False, threading.Event()
        self.lock = threading.Lock()
    def append(self, chunk):
        with self.lock:
            self.observed += len(chunk)
            if len(chunk) > self.maximum - len(self.data): self.over = True
            elif not self.over: self.data.extend(chunk)
    def consume(self, stream):
        try:
            while chunk := os.read(stream.fileno(), 4096): self.append(chunk)
        except Exception: self.error = True
        finally: self.done.set()
    def metadata(self):
        with self.lock:
            return {'observedBytes': self.observed, 'retainedBytes': len(self.data),
                    'sha256': digest(self.data), 'overBudget': self.over,
                    'drained': self.done.is_set() and not self.error}
    def frozen(self):
        with self.lock:
            data = bytes(self.data)
            metadata = {'observedBytes': self.observed, 'retainedBytes': len(data),
                        'sha256': digest(data), 'overBudget': self.over,
                        'drained': self.done.is_set() and not self.error}
            return data, metadata


def sample(executable, arguments, environment, out, name, maximum=MAX_STDOUT):
    began = time.monotonic()
    deadline = began + 5
    stdout, stderr = BoundedStream(maximum), BoundedStream(MAX_STDERR)
    job, child, threads = None, None, []
    outcome, exit_code, quiescent = 'launch_failed', None, False
    observation = {}
    snapshots = {}
    try:
        job = WindowsJob()
        child = subprocess.Popen([str(executable), *arguments], env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=4)
        job.assign_and_resume(child)
        for stream, pipe in ((stdout, child.stdout), (stderr, child.stderr)):
            thread = threading.Thread(target=stream.consume, args=(pipe,), daemon=True)
            thread.start(); threads.append(thread)
        outcome = 'completed'
        while child.poll() is None:
            if stdout.over or stderr.over:
                outcome = 'output_budget'; break
            if time.monotonic() >= deadline:
                outcome = 'deadline'; break
            time.sleep(0.002)
        if outcome != 'completed': job.terminate()
        child.wait(timeout=2)
        # A foreground exit cannot hide active descendants or a late PE. Native
        # job accounting can still be nonzero immediately after parent exit;
        # require an actual zero observation within the SAME original deadline.
        observation = observe_quiescence(job, deadline)
        quiescent = observation['ownedQuiescenceObservedBeforeDeadline']
        if not quiescent:
            outcome = 'descendants_not_quiescent'; job.terminate()
        for thread in threads: thread.join(timeout=1)
        exit_code = child.returncode
        if not stdout.metadata()['drained'] or not stderr.metadata()['drained']:
            outcome = 'output_drain_failure'
        elif stdout.over or stderr.over: outcome = 'output_budget'
        elif outcome == 'completed' and exit_code != 0: outcome = 'child_failed'
    except Exception:
        outcome = 'launch_or_ownership_failed'
    finally:
        if job:
            try: job.terminate()
            finally: job.close()
        if child and child.poll() is None:
            child.kill(); child.wait(timeout=2)
        for thread in threads: thread.join(timeout=1)
        if child:
            for pipe, stream in ((child.stdout, stdout), (child.stderr, stderr)):
                if stream.done.is_set(): pipe.close()
        # Raw bytes only enter this owner-protected directory and sealed tar.
        for suffix, stream in (('stdout', stdout), ('stderr', stderr)):
            data, metadata = stream.frozen(); snapshots[suffix] = metadata
            path = out / (name + '-' + suffix + '.log')
            if unsafe_path(path) or path.exists(): raise ValueError('raw_output_type')
            private_file(path, data)
    return {'outcome': outcome, 'exitCode': exit_code, 'stdout': snapshots['stdout'],
            'stderr': snapshots['stderr'], 'ownedDescendantsQuiescentBeforeCleanup': quiescent,
            **observation,
            'deadlineSeconds': 5,
            'elapsedMilliseconds': round((time.monotonic() - began) * 1000, 3)}


def natural(sample):
    return (sample['outcome'] in ('completed', 'child_failed') and sample['exitCode'] is not None
            and sample['ownedDescendantsQuiescentBeforeCleanup']
            and all(sample[s]['drained'] and not sample[s]['overBudget'] for s in ('stdout', 'stderr')))


def use_owned_renderer(samples):
    return (len(samples) == 5 and [s['profile'] for s in samples] == list(PROFILES)
            and all(s['renderer'] == 'packed_body' and natural(s)
                    and s['exitCode'] != 0 and not s['freshPE'] for s in samples))


def valid_pe(data):
    if len(data) < 64 or data[:2] != b'MZ': return False
    offset = struct.unpack_from('<I', data, 60)[0]
    return offset <= len(data) - 6 and data[offset:offset + 6] == b'PE\x00\x00\x64\x86'


def checked_read(path, maximum):
    if unsafe_path(path) or not path.is_file() or not 0 < path.stat().st_size <= maximum:
        raise ValueError('input_type_or_budget')
    with path.open('rb') as stream: data = stream.read(maximum + 1)
    if len(data) != path.stat().st_size or len(data) > maximum: raise ValueError('input_changed')
    return data


def command(args):
    return subprocess.run(args, capture_output=True, timeout=30)


def git(*args):
    result = command(['git', *args])
    if result.returncode: raise ValueError('source_provenance')
    return result.stdout


def crypto(executable, recipient, source, output):
    args = [str(executable), 'cms', '-encrypt', '-binary', '-aes-256-gcm',
            '-in', str(source), '-out', str(output), '-outform', 'DER',
            '-recip', str(recipient), '-keyopt', 'rsa_padding_mode:oaep',
            '-keyopt', 'rsa_oaep_md:sha256', '-keyopt', 'rsa_mgf1_md:sha256']
    try:
        if command(args).returncode: raise ValueError('encryption_failed')
        result = command([str(executable), 'cms', '-cmsout', '-inform', 'DER', '-in', str(output), '-print'])
        if result.returncode: raise ValueError('encryption_algorithms')
        checked_algorithms(result.stdout)
    except Exception:
        output.unlink(missing_ok=True); raise


def checked_algorithms(data):
    if (data.count(b'contentType: id-smime-ct-authEnvelopedData') != 1
            or data.count(b'algorithm: aes-256-gcm') != 1 or data.count(b'algorithm: rsaesOaep') != 1):
        raise ValueError('encryption_algorithms')
    block = re.search(rb'keyEncryptionAlgorithm:(.*?)encryptedKey:', data, re.S)
    if not block or re.findall(rb'OBJECT\s+:([a-z0-9]+)', block[1]) != [b'sha256', b'mgf1', b'sha256']:
        raise ValueError('encryption_algorithms')


def seal(directory, output, openssl, recipient):
    plain, manifest = directory / 'owned.tar', {}
    private_file(plain, b'')
    with tarfile.open(plain, 'w', format=tarfile.USTAR_FORMAT) as tar:
        for path in sorted(directory.glob('*.log')):
            if path.name not in RAW_NAMES or path.name in manifest: raise ValueError('raw_export_name')
            if unsafe_path(path) or not path.is_file() or path.stat().st_size > MAX_STDERR: raise ValueError('raw_export_budget')
            data = path.read_bytes(); manifest[path.name] = {'bytes': len(data), 'sha256': digest(data)}
            info = tarfile.TarInfo(path.name); info.size = len(data); info.mode = 0o600
            tar.addfile(info, io.BytesIO(data))
    try:
        if len(manifest) > 22 or sum(x['bytes'] for x in manifest.values()) > 720_896: raise ValueError('raw_total_budget')
        if digest(checked_read(recipient, 16_384)) != CERT_SHA: raise ValueError('recipient_changed')
        crypto(openssl, recipient, plain, output)
        return {'recipientPublicCertificateSHA256': CERT_SHA, 'plaintextArchiveSHA256': digest(plain.read_bytes()),
                'encryptedSHA256': digest(output.read_bytes()), 'encryptedBytes': output.stat().st_size, 'whitelistFiles': manifest}
    finally: plain.unlink(missing_ok=True)


def main(openssl):
    safe, private = Path('compiler-matrix-safe'), Path('compiler-matrix-private')
    report = {'status': 'STARTED', 'diagnosticOnly': True, 'productionEnvironmentChanged': False,
              'productionFoundationRepairClaimed': False, 'providerGREENClaimed': False,
              'rawPathsEnvironmentArgumentsOrStreamsPublished': False,
              'transport': 'PythonNativeSubprocessOwnedWindowsJobNotFoundation'}
    code, recipient = 125, None
    try:
        if os.name != 'nt' or sys.version_info[:2] != (3, 12): raise ValueError('native_toolchain')
        private_directory(safe); private_directory(private)
        report['privateOutputOwnerACLValidatedBeforeCapture'] = True
        if (git('rev-parse', SOURCE + ':Sources').decode().strip() != SOURCES_TREE
                or git('diff', SOURCE, '--', *INPUTS) or git('ls-files', '--others', '--exclude-standard', '--', *INPUTS)):
            raise ValueError('source_inputs')
        report.update(physicalHead=git('rev-parse', 'HEAD').decode().strip(), reviewedSource=SOURCE,
                      runtimeSourcesTree=SOURCES_TREE, packagedInputsEqualReviewedSource=True)
        cert = git('show', 'HEAD:.github/windows-focused-recipient-public.pem')
        if digest(cert) != CERT_SHA: raise ValueError('recipient_pin')
        checked_read(openssl, 64 * 1024 * 1024)
        report['opensslSHA256'] = digest(openssl.read_bytes())
        recipient = private / 'recipient.pem'; private_file(recipient, cert, read_only=True)
        selected = selected_host_context(os.environ)
        environments = profiles(selected, tempfile.gettempdir())
        for value in (selected['ProgramData'], selected['SystemRoot'], environments[1]['PATH']):
            if unsafe_path(Path(value)) or not Path(value).is_dir(): raise ValueError('known_location_directory')
        where = Path(host_path(selected['ProgramFiles(x86)'])) / 'Microsoft Visual Studio/Installer/vswhere.exe'
        where_bytes = checked_read(where, 8_388_608)
        query = sample(where, QUERY_ARGS, environments[2], private, 'query', maximum=32_768)
        report['installationQuery'] = query
        if not natural(query) or query['exitCode'] != 0: raise ValueError('installation_query')
        installed = (private / 'query-stdout.log').read_bytes()
        if installed.startswith(b'\xef\xbb\xbf'): raise ValueError('installation_bom')
        installation = host_path(installed.decode('utf-8').strip())
        setup = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
        executable = Path(environments[0]['SystemRoot']) / 'System32/cmd.exe'
        source, header, script = (private / name for name in ('client-launcher.c', 'windows-python-client-paths.h', 'owned-script.py'))
        client, obj = private / 'client.exe', private / 'client.obj'
        interpreter = host_path(sys.executable)
        literal = lambda value: value.replace('\\', '\\\\').replace('"', '\\"')
        native = lambda path: str(path.absolute()).replace('/', '\\')
        private_file(source, checked_read(Path('Tests/Fixtures/windows-python-client-launcher.c'), 65_536), read_only=True)
        private_file(script, b'raise SystemExit(0)\n', read_only=True)
        private_file(header, ('#define RIGHTCLICK_FIXTURE_PYTHON L"' + literal(interpreter) + '"\n#define RIGHTCLICK_FIXTURE_SCRIPT L"' + literal(str(script.absolute())) + '"\n').encode('utf-8'), read_only=True)
        batch = 'call "' + native(setup) + '" > nul && cl /nologo /std:c17 "' + native(source) + '" /Fe:"' + native(client) + '" /Fo:"' + native(obj) + '"'
        owned_batch = private / 'compile-client.bat'
        private_file(owned_batch, ('@echo off\r\n' + batch + '\r\n').encode('ascii'), read_only=True)
        frozen_paths = [(where, 8_388_608), (executable, 8_388_608), (setup, 1_048_576), (source, 65_536), (header, 32_768), (script, 128), (owned_batch, 32_768)]
        frozen = [checked_read(path, maximum) for path, maximum in frozen_paths]
        report['directInputSHA256'] = dict(zip(('installedQuery', 'cmd', 'setupBatch', 'ownedC', 'ownedHeader', 'ownedScript', 'ownedBatch'), map(digest, frozen)))
        report['fixedCallCompilerBodyUTF16SHA256'] = digest(batch.encode('utf-16-le'))
        report['ownedBatchOwnerACLAndReadonlyValidated'] = True
        samples = []; report['samples'] = samples; report['renderers'] = []
        renderers = [('packed_body', 'packed', ['/d', '/s', '/c', batch]),
                     ('owned_fixed_batch', 'owned', ['/d', '/c', str(owned_batch.absolute())])]
        for renderer_index, (renderer, prefix, arguments) in enumerate(renderers):
            if renderer_index == 1 and not use_owned_renderer(samples): break
            argument_hash = digest(json.dumps(arguments, separators=(',', ':'), ensure_ascii=False).encode('utf-16-le'))
            rendered_hash = digest(subprocess.list2cmdline([str(executable), *arguments]).encode('utf-16-le'))
            report['renderers'].append({'renderer': renderer, 'argumentUTF16SHA256': argument_hash,
                                      'pythonRenderedCommandLineUTF16SHA256': rendered_hash})
            for index, (name, environment) in enumerate(zip(PROFILES, environments)):
                for path in (client, obj):
                    if unsafe_path(path): raise ValueError('owned_output_redirect')
                    path.unlink(missing_ok=True)
                if any(path.exists() for path in (client, obj)): raise ValueError('output_not_fresh')
                if [checked_read(path, maximum) for path, maximum in frozen_paths] != frozen: raise ValueError('direct_input_changed')
                measured = sample(executable, arguments, environment, private, f'{prefix}-{index}')
                emitted = checked_read(client, 8_388_608) if client.exists() else b''
                samples.append({'renderer': renderer, 'profile': name, **measured, 'outputsAbsentBefore': True,
                                'freshPE': valid_pe(emitted), 'outputSHA256': digest(emitted) if emitted else None,
                                'argumentUTF16SHA256': argument_hash, 'pythonRenderedCommandLineUTF16SHA256': rendered_hash})
                # Abort before another context/renderer after any unsafe state.
                if not natural(measured): raise ValueError('matrix_non_natural_abort')
        report['directInputsUnchanged'] = [checked_read(path, maximum) for path, maximum in frozen_paths] == frozen
        report['installedQueryUnchanged'] = checked_read(where, 8_388_608) == where_bytes
        if not report['directInputsUnchanged'] or not report['installedQueryUnchanged']: raise ValueError('direct_input_changed')
        if (git('rev-parse', 'HEAD').decode().strip() != report['physicalHead']
                or git('diff', SOURCE, '--', *INPUTS) or git('ls-files', '--others', '--exclude-standard', '--', *INPUTS)):
            raise ValueError('packaged_input_changed')
        report['packagedInputsUnchangedAfterMatrix'] = True
        report['status'] = 'MATRIX_MEASURED_DIAGNOSTIC_ONLY'; code = 0
        report['limits'] = ['Python list2cmdline rendering is not Foundation/BPC argument rendering proof.', 'The owned batch diagnostic uses an ASCII-only fixed body and is a distinct renderer.', 'Transitive SDK/linker/Python bytes are not individually frozen.', 'Valid PE proves compiler output only; no invocation/effect/receipt or environment authority promotion.']
    except Exception as error:
        report['status'] = 'FAILED_CLOSED'; report['errorType'] = type(error).__name__
        if type(error) is ValueError and re.fullmatch('[a-z_]{1,64}', str(error)): report['errorLabel'] = str(error)
    finally:
        try:
            if private.is_dir() and recipient and any(private.glob('*.log')):
                report['privateEvidence'] = seal(private, safe / 'owned-compiler-matrix.cms', openssl, recipient)
            if safe.is_dir(): (safe / 'summary.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
        except Exception as error:
            (safe / 'owned-compiler-matrix.cms').unlink(missing_ok=True)
            report = {'status': 'PRIVATE_EVIDENCE_FAILED_CLOSED', 'errorType': type(error).__name__, 'diagnosticOnly': True}
            if safe.is_dir(): (safe / 'summary.json').write_text(json.dumps(report) + '\n', encoding='utf-8')
            code = 125
    print(json.dumps({'status': report['status'], 'diagnosticOnly': True}, separators=(',', ':')))
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openssl', type=Path, required=True)
    options = parser.parse_args()
    raise SystemExit(main(options.openssl))
