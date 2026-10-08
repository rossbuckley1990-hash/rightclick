#!/usr/bin/env python3
from pathlib import Path
import importlib.util, json, struct, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import windows_compiler_context_matrix as m


class MatrixControls(unittest.TestCase):
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

    def test_raw_export_names_are_closed_and_twenty_two_only(self):
        self.assertEqual(len(m.RAW_NAMES), 22)
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
