#!/usr/bin/env python3
from pathlib import Path
import ast, ctypes, importlib.util, json, os, shutil, struct, subprocess, sys, tempfile, time, unittest, uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import windows_compiler_context_matrix as m


class MatrixControls(unittest.TestCase):
    def test_owned_process_projection_rejects_paths_and_never_exposes_pid(self):
        rows = [{'root': False, 'imageName': 'VCTIP.EXE', 'pid': 123},
                {'root': False, 'imageName': 'unknown-owned-fixed-canary.exe', 'pid': 124},
                {'root': True, 'imageName': 'cmd.exe', 'pid': 125}]
        result = m.owned_process_roles(rows)
        self.assertEqual(result['fixedNameRoleCounts'], {'compiler_telemetry_name': 1})
        self.assertEqual(result['rootRows'], 1)
        self.assertNotIn('unknown-owned-fixed-canary', json.dumps(result))
        self.assertNotIn('pid', json.dumps(result))
        for name in ('C:\\private\\host.exe', '../host', 'host\nname'):
            with self.assertRaises(ValueError): m.owned_process_roles([{'root': False, 'imageName': name}])
        with self.assertRaises(ValueError): m.owned_process_roles(rows * 22)

    def test_fixed_bootstrap_source_is_evidenced_without_flag_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            file = root / m.BOOTSTRAP_SCRIPTS[2][1]; file.parent.mkdir(parents=True)
            file.write_bytes(b'@echo off\nif "%VSCMD_SKIP_SENDTELEMETRY%"=="1" goto end\n:end\n')
            public, private, snapshots = m.bootstrap_evidence(root)
            self.assertTrue(public['fixedReferenceObserved']); self.assertFalse(public['optOutFlagApplied'])
            self.assertEqual(public['fixedReferenceOccurrences'], 1)
            self.assertIn(b'goto end', private); self.assertLessEqual(len(private), 32768)
            self.assertTrue(m.bootstrap_unchanged(snapshots))
            file.write_bytes(b'changed')
            self.assertFalse(m.bootstrap_unchanged(snapshots))

    def test_bootstrap_evidence_bounds_excerpts_and_detects_added_missing_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            file = root / m.BOOTSTRAP_SCRIPTS[0][1]; file.parent.mkdir(parents=True)
            file.write_bytes((b'VSCMD_SKIP_SENDTELEMETRY' + b'x' * 2048 + b'\n') * 30)
            public, private, snapshots = m.bootstrap_evidence(root)
            self.assertEqual(public['fixedReferenceOccurrences'], 30)
            self.assertEqual(public['sourceExcerptsCaptured'], 16)
            self.assertLessEqual(len(private), 32768)
            missing = root / m.BOOTSTRAP_SCRIPTS[2][1]; missing.parent.mkdir(parents=True)
            missing.write_bytes(b'@echo off\n')
            self.assertFalse(m.bootstrap_unchanged(snapshots))

    def test_accounting_lag_requires_actual_zero_within_original_budget(self):
        clock = [1.0]; values = iter((2, 1, 0))
        def pause(seconds): clock[0] += seconds
        observed = m.observe_quiescence(None, 1.005, query=lambda _: next(values), now=lambda: clock[0], pause=pause)
        self.assertTrue(observed['ownedQuiescenceObservedBeforeDeadline'])
        self.assertEqual((observed['initialOwnedActiveProcesses'], observed['finalOwnedActiveProcesses']), (2, 0))
        self.assertEqual(observed['ownedQuiescencePolls'], 3)
        self.assertEqual(observed['postParentRemainingBudgetMilliseconds'], 5)
        self.assertEqual(observed['ownedQuiescenceWaitMilliseconds'], 4)

    def test_active_descendants_abort_at_original_deadline(self):
        clock = [1.0]
        def pause(seconds): clock[0] += seconds
        observed = m.observe_quiescence(None, 1.005, query=lambda _: 1, now=lambda: clock[0], pause=pause)
        self.assertFalse(observed['ownedQuiescenceObservedBeforeDeadline'])
        self.assertEqual(observed['finalOwnedActiveProcesses'], 1)
        self.assertEqual(observed['ownedQuiescenceWaitMilliseconds'], 5)

    def test_late_zero_observation_cannot_cross_original_deadline(self):
        clock = [1.0]
        def late_query(_): clock[0] = 1.006; return 0
        observed = m.observe_quiescence(None, 1.005, query=late_query, now=lambda: clock[0])
        self.assertFalse(observed['ownedQuiescenceObservedBeforeDeadline'])
        self.assertEqual(observed['finalOwnedActiveProcesses'], 0)

    @unittest.skipUnless(os.name == 'nt', 'Owned native job quiescence requires Windows')
    def test_native_owned_job_observes_natural_zero_and_rejects_still_active(self):
        selected = m.selected_host_context(os.environ)
        environment = m.profiles(selected, tempfile.gettempdir())[0]
        for lifetime, budget, expected in ((0.05, 2, True), (2, 0.02, False)):
            job, child = None, None
            try:
                job = m.WindowsJob()
                child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(' + str(lifetime) + ')'],
                    env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, creationflags=4)
                job.assign_and_resume(child)
                observed = m.observe_quiescence(job, time.monotonic() + budget)
                self.assertGreater(observed['initialOwnedActiveProcesses'], 0)
                self.assertEqual(observed['ownedQuiescenceObservedBeforeDeadline'], expected)
                if expected:
                    self.assertEqual(observed['finalOwnedActiveProcesses'], 0)
                    self.assertEqual(child.wait(timeout=1), 0)
                else: self.assertGreater(observed['finalOwnedActiveProcesses'], 0)
            except Exception as error:
                raise AssertionError('native_owned_quiescence_control_failed_' + type(error).__name__) from None
            finally:
                if job:
                    try: job.terminate()
                    finally: job.close()
                if child:
                    try: child.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait(timeout=2)

    def test_private_payload_parameter_cannot_be_reassigned(self):
        code = ast.parse((ROOT / '.github/scripts/windows_compiler_context_matrix.py').read_text())
        function = next(n for n in code.body if isinstance(n, ast.FunctionDef) and n.name == 'private_object')
        self.assertIn('data', [a.arg for a in function.args.args])
        self.assertFalse(any(isinstance(n, ast.Name) and n.id == 'data' and isinstance(n.ctx, ast.Store) for n in ast.walk(function)))

    @unittest.skipUnless(os.name == 'nt', 'Protected Windows file roundtrip requires native Windows')
    def test_native_owner_acl_exact_payload_readonly_and_exclusive_roundtrip(self):
        from ctypes import wintypes as w
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.GetFileAttributesW.argtypes, kernel.GetFileAttributesW.restype = [w.LPCWSTR], w.DWORD
        kernel.SetFileAttributesW.argtypes, kernel.SetFileAttributesW.restype = [w.LPCWSTR, w.DWORD], w.BOOL
        root = Path(tempfile.gettempdir()) / ('rightclick-private-file-control-' + uuid.uuid4().hex)
        file = root / 'fixed-owned-canary.bin'
        payload = b'RIGHTCLICK fixed private file canary\x00\x01\xff'
        try:
            m.private_directory(root)
            m.private_file(file, payload, read_only=True)
            self.assertTrue(m.checked_read(file, 128) == payload)
            attrs = kernel.GetFileAttributesW(str(file.absolute()))
            self.assertNotEqual(attrs, 0xffffffff); self.assertTrue(attrs & 1)
            with self.assertRaises(ValueError): m.private_file(file, b'wrong replacement')
            with self.assertRaises(OSError): file.write_bytes(b'wrong replacement')
            self.assertTrue(m.checked_read(file, 128) == payload)
        except Exception as error:
            raise AssertionError('native_private_file_roundtrip_failed_' + type(error).__name__) from None
        finally:
            try:
                if file.exists() and not kernel.SetFileAttributesW(str(file.absolute()), 0x80):
                    raise RuntimeError('owned_control_attribute_release')
                if root.exists(): shutil.rmtree(root)
            except Exception as error:
                raise AssertionError('native_private_owned_cleanup_failed_' + type(error).__name__) from None

    def test_reads_only_three_fixed_keys_never_ambient_path(self):
        class Environment:
            def __init__(self): self.keys = []
            def get(self, key):
                self.keys.append(key)
                if key not in ('SystemRoot', 'ProgramData', 'ProgramFiles(x86)'): raise AssertionError('nonfixed lookup')
                return 'C:\\' + key
            def __iter__(self): raise AssertionError('ambient enumeration')
        env = Environment(); m.selected_host_context(env)
        self.assertEqual(env.keys, ['SystemRoot', 'ProgramData', 'ProgramFiles(x86)'])

    def test_profiles_have_only_minimum_and_explicit_two_roles(self):
        selected = {'SystemRoot': 'C:\\Windows', 'ProgramData': 'C:\\ProgramData', 'ProgramFiles(x86)': 'C:\\Programs'}
        p = m.profiles(selected, 'C:\\Temp')
        baseline = {'SystemRoot', 'TEMP', 'TMP'}
        self.assertEqual([set(x) for x in p], [baseline, baseline | {'PATH'}, baseline | {'ProgramData'}, baseline | {'PATH', 'ProgramData'}, baseline])
        self.assertEqual(p[1]['PATH'], 'C:\\Windows\\System32')
        self.assertEqual(p[0], p[4])

    def test_missing_or_extra_host_context_fails_closed(self):
        for selected in ({}, {'SystemRoot': 'C:\\Windows', 'ProgramData': 'C:\\ProgramData', 'ProgramFiles(x86)': 'C:\\Programs', 'PATH': 'private-canary'}):
            with self.assertRaises(ValueError): m.profiles(selected, 'C:\\Temp')

    def test_ambiguous_remote_and_unbounded_paths_rejected(self):
        for value in ('', 'relative', 'C:relative', '\\\\server\\share', '\\\\?\\C:\\data', 'C:\\a\\..\\b', 'C:\\a\\.\\b', 'C:\\a\\', 'C:\\a ', 'C:\\a.', 'C:\\a\x00b', 'C:\\a\nb', 'C:\\a"b', 'C:\\a:stream', 'C:\\' + 'x' * 4094):
            with self.subTest(case=value[:8]):
                with self.assertRaises(ValueError): m.host_path(value)

    def test_system_search_cannot_be_a_path_list(self):
        with self.assertRaises(ValueError): m.host_path('C:\\a;D:\\b', search=True)
        with self.assertRaises(ValueError): m.profiles({'SystemRoot': 'C:\\a;b', 'ProgramData': 'C:\\Data', 'ProgramFiles(x86)': 'C:\\Programs'}, 'C:\\Temp')

    def test_no_raw_values_in_profile_public_names(self):
        self.assertEqual(m.PROFILES, ('minimal_before', 'fixed_system_executable_search', 'machine_application_data', 'machine_data_and_system_search', 'minimal_after'))
        self.assertTrue(all('C:' not in x for x in m.PROFILES))

    def test_stream_never_retains_beyond_cap_even_after_overrun(self):
        stream = m.BoundedStream(8)
        stream.append(b'fixed123'); stream.append(b'private-overflow'); stream.append(b'more')
        data, meta = stream.frozen()
        self.assertEqual(data, b'fixed123'); self.assertTrue(meta['overBudget'])
        self.assertEqual(meta['retainedBytes'], 8)
        self.assertEqual(meta['observedBytes'], 8 + len(b'private-overflow') + 4)
        self.assertFalse(meta['drained'])

    def test_frozen_stream_bytes_match_their_metadata(self):
        stream = m.BoundedStream(8); stream.append(b'owned'); stream.done.set()
        data, meta = stream.frozen()
        self.assertEqual(meta['sha256'], m.digest(data)); self.assertEqual(meta['retainedBytes'], len(data)); self.assertTrue(meta['drained'])

    def test_drain_error_does_not_become_natural(self):
        stream = m.BoundedStream(8); stream.done.set(); stream.error = True
        self.assertFalse(stream.frozen()[1]['drained'])

    def test_only_natural_quiescent_fully_drained_sample_can_advance(self):
        base = {'outcome': 'child_failed', 'exitCode': 1, 'ownedDescendantsQuiescentBeforeCleanup': True,
                'stdout': {'drained': True, 'overBudget': False}, 'stderr': {'drained': True, 'overBudget': False}}
        self.assertTrue(m.natural(base))
        for key, value in [('outcome', 'deadline'), ('outcome', 'output_budget'), ('outcome', 'output_drain_failure'), ('outcome', 'descendants_not_quiescent'), ('exitCode', None), ('ownedDescendantsQuiescentBeforeCleanup', False)]:
            self.assertFalse(m.natural({**base, key: value}))
        for stream in ('stdout', 'stderr'):
            for key in ('drained', 'overBudget'):
                self.assertFalse(m.natural({**base, stream: {**base[stream], key: key != 'drained'}}))

    def test_pe_requires_signature_machine_and_bounded_offset(self):
        pe = bytearray(80); pe[:2] = b'MZ'; struct.pack_into('<I', pe, 60, 64); pe[64:70] = b'PE\x00\x00\x64\x86'
        self.assertTrue(m.valid_pe(pe))
        for bad in (b'MZ', bytes(80), pe[:65]): self.assertFalse(m.valid_pe(bad))
        pe[68] = 0; self.assertFalse(m.valid_pe(pe))
        struct.pack_into('<I', pe, 60, 0xffffffff); self.assertFalse(m.valid_pe(pe))

    def test_owned_renderer_requires_all_five_natural_failures_without_pe(self):
        samples = [{'renderer': 'packed_body', 'profile': p, 'outcome': 'child_failed', 'exitCode': 1,
                    'ownedDescendantsQuiescentBeforeCleanup': True, 'freshPE': False,
                    'stdout': {'drained': True, 'overBudget': False}, 'stderr': {'drained': True, 'overBudget': False}} for p in m.PROFILES]
        self.assertTrue(m.use_owned_renderer(samples))
        self.assertFalse(m.use_owned_renderer(samples[:-1]))
        self.assertFalse(m.use_owned_renderer(samples[::-1]))
        for key, value in [('exitCode', 0), ('freshPE', True), ('outcome', 'deadline'), ('renderer', 'owned_fixed_batch')]:
            bad = [dict(s) for s in samples]; bad[2][key] = value
            self.assertFalse(m.use_owned_renderer(bad))

    def test_raw_export_names_are_closed_and_twenty_three_only(self):
        self.assertEqual(len(m.RAW_NAMES), 23)
        self.assertIn('bootstrap-evidence.log', m.RAW_NAMES)
        self.assertNotIn('environment.json', m.RAW_NAMES); self.assertNotIn('../stderr.log', m.RAW_NAMES)

    def test_redirected_input_and_oversize_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(); file = root / 'owned'; file.write_bytes(b'bounded')
            alias = root / 'alias'; alias.symlink_to(file)
            with self.assertRaises(ValueError): m.checked_read(alias, 100)
            with self.assertRaises(ValueError): m.checked_read(file, 3)
            self.assertEqual(m.checked_read(file, 100), b'bounded')

    def test_crypto_rejects_cbc_duplicate_and_wrong_oaep_hash(self):
        good = b'contentType: id-smime-ct-authEnvelopedData\nkeyEncryptionAlgorithm:\nalgorithm: rsaesOaep\nOBJECT :sha256\nOBJECT :mgf1\nOBJECT :sha256\nencryptedKey:\nalgorithm: aes-256-gcm\n'
        m.checked_algorithms(good)
        for bad in (good.replace(b'aes-256-gcm', b'aes-256-cbc'), good + good, good.replace(b'sha256', b'sha1', 1)):
            with self.assertRaises(ValueError): m.checked_algorithms(bad)


if __name__ == '__main__': unittest.main(verbosity=2)
