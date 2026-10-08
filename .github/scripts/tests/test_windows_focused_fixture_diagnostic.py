#!/usr/bin/env python3
"""Collector controls use synthetic data; only a real Windows run proves fixtures."""
import contextlib
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / '.github/scripts'))
import windows_focused_fixture_diagnostic as d

EXPECTED = set(json.loads((ROOT / '.github/windows-current-context-focused-17-names.json').read_text()))
BASELINE = set(json.loads((ROOT / '.github/windows-current-native-baseline-tests.json').read_text())['names'])
ALGORITHMS = b'''contentType: id-smime-ct-authEnvelopedData
keyEncryptionAlgorithm:
algorithm: rsaesOaep
parameter: SEQUENCE:
OBJECT :sha256
OBJECT :mgf1
OBJECT :sha256
encryptedKey:
algorithm: aes-256-gcm
'''


def log(state='passed'):
    return '\n'.join(f"Test Case '{n.split('.', 1)[1].replace('/', '.')}' started\n"
                     f"Test Case '{n.split('.', 1)[1].replace('/', '.')}' {state} (0.001 seconds)"
                     for n in sorted(EXPECTED)) + '\nTest run with 0 tests in 0 suites passed\n'


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rightclick-focused-control-')
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_all_686_baseline_names_required_even_with_693_total(self):
        # Synthetic extra names exercise the guard; they are not native evidence.
        extra = EXPECTED - BASELINE
        current = BASELINE | extra
        d.inventory('\n'.join(current), EXPECTED, BASELINE)
        dropped = next(iter(BASELINE))
        replaced = (current - {dropped}) | {'RightClickCoreTests.SyntheticControl/testReplacement'}
        with self.assertRaisesRegex(ValueError, 'inventory_preservation'):
            d.inventory('\n'.join(replaced), EXPECTED, BASELINE)

    def test_duplicate_and_malformed_name_inventory_rejected(self):
        for bad in [[{}, 'a'], ['RightClickCoreTests.A/testA'] * 2]:
            with self.assertRaises(ValueError):
                d.checked_names(bad, 2)

    def test_filter_selects_exact_seventeen_and_rejects_similar_class_names(self):
        self.assertEqual({name for name in (BASELINE | EXPECTED) if re.search(d.FILTER, name)}, EXPECTED)
        similar = 'RightClickCoreTests.RCIRInvocationBindingTests/testOnlyHostTaskIdentityCanVerifyMatchingObservation'
        self.assertIn(similar, BASELINE)
        self.assertIsNone(re.search(d.FILTER, similar))
        self.assertIsNone(re.search(d.FILTER,
            'RightClickCoreTests.UnrelatedInvocationBindingTests/testExtra'))

    def test_complete_seventeen_and_failure_are_distinct(self):
        result = d.execution(log(), EXPECTED)
        self.assertEqual((result['passes'], result['failures'], result['skips']), (17, 0, 0))
        failed = d.execution(log().replace(' passed (', ' failed (', 1), EXPECTED)
        self.assertEqual((failed['passes'], failed['failures']), (16, 1))
        self.assertTrue(result['swiftTestingZeroSuiteObserved'])

    def test_truncated_duplicate_or_unselected_completion_rejected(self):
        good = log()
        for bad in [good.splitlines()[2:], good + good,
                    good.replace('testFreshMarkersVerifyForBothTransports', 'testUnselected')]:
            with self.assertRaises(ValueError):
                d.execution('\n'.join(bad) if isinstance(bad, list) else bad, EXPECTED)

    def test_skipped_case_never_counted_as_pass(self):
        result = d.execution(log().replace(' passed (', ' skipped (', 1), EXPECTED)
        self.assertEqual((result['passes'], result['skips']), (16, 1))

    def test_closed_bootstrap_flags_and_stage_without_private_values(self):
        line = ('NativePythonClient stage=installationValidation kind=unavailable '
                'processOutcome=completed started=true exit=0 stdoutBytes=10 '
                'validation=[empty=false isAbsolute=true containsQuote=false '
                'containsEmbeddedLF=false startsUTF8BOM=false]')
        result = d.stages(line + ' bearer=private-control-sentinel')
        self.assertEqual(result['bootstrap'][0]['stage'], 'installationValidation')
        self.assertEqual(result['bootstrap'][0]['isAbsolute'], 'true')
        self.assertNotIn('private-control-sentinel', json.dumps(result))
        for bad in [line.replace('unavailable', 'privateLabel'),
                    line.replace('completed', 'privateLabel'),
                    line.replace('installationValidation', 'privateLabel')]:
            self.assertEqual(d.stages(bad)['bootstrap'], [])

    def test_invocation_closed_labels_bound_to_actual_test_interval(self):
        name = 'RightClickCoreTests.InvocationBindingTests/testFreshMarkersVerifyForBothTransports'
        short = name.split('.', 1)[1].replace('/', '.')
        line = ('InvocationBindingFixture stage=resolverAcquisition substrate=kafka '
                'kind=unavailable kafkaStage=metadataProcess processOutcome=childFailed '
                'started=true exit=1 bootstrap=[none]')
        text = f"{line}\nTest Case '{short}' started\n{line}\nTest Case '{short}' failed (0.1 seconds)"
        result = d.bound_stages(text, EXPECTED)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['test'], name)
        self.assertEqual(len(result[0]['stages']['invocation']), 1)
        self.assertEqual(d.stages(line.replace('metadataProcess', 'privateLabel'))['invocation'], [])

    def test_archive_whitelist_hashes_exact_retained_bytes(self):
        file = self.root / 'owned.json'
        file.write_bytes(b'{"synthetic":true}\n')
        output = self.root / 'owned.tar'
        result = d.archive([('trust-results.json', file)], output)
        with tarfile.open(output) as tar:
            item = tar.getmember('trust-results.json')
            self.assertEqual((item.mode, item.uid, item.gid), (0o600, 0, 0))
            self.assertEqual(tar.extractfile(item).read(), file.read_bytes())
        self.assertEqual(result['trust-results.json']['sha256'], d.digest(file.read_bytes()))
        with self.assertRaises(ValueError):
            d.archive([('signer.raw', file)], self.root / 'rejected.tar')

    def test_archive_size_and_total_budget_reject(self):
        file = self.root / 'owned.json'
        file.write_bytes(b'abcde')
        with patch.object(d, 'MAX_FILE', 4), self.assertRaises(ValueError):
            d.archive([('trust-results.json', file)], self.root / 'one.tar')
        with patch.object(d, 'MAX_TOTAL', 9), self.assertRaises(ValueError):
            d.archive([('trust-results.json', file), ('runtime-records.json', file)], self.root / 'two.tar')

    def test_all_phase_logs_are_encrypted_whitelist_inputs_even_before_tests(self):
        files = []
        for phase, name in d.PHASE_LOGS.items():
            path = self.root / (phase + '-output.log')
            path.write_bytes((phase + '-private-control-sentinel').encode())
            files.append((name, path))
        archived = self.root / 'phase-logs.tar'
        manifest = d.archive(files, archived)
        self.assertEqual(set(manifest), {'build-output.log', 'discovery-output.log',
                                        'focused-test-output.log'})
        with tarfile.open(archived) as tar:
            self.assertEqual({entry.name for entry in tar}, set(manifest))
        with self.assertRaises(ValueError):
            d.archive([('controller-output.log', files[0][1])], self.root / 'unlisted.tar')

    def test_symlink_parent_or_native_junction_rejected(self):
        file = self.root / 'owned.json'
        file.write_bytes(b'owned')
        alias = self.root / 'alias'
        if os.name == 'nt':
            result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(alias), str(self.root)],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
        else:
            alias.symlink_to(self.root, target_is_directory=True)
        try:
            with self.assertRaises(ValueError):
                d.archive([('trust-results.json', alias / file.name)], self.root / 'no.tar')
        finally:
            if os.name == 'nt':
                os.rmdir(alias)
            else:
                alias.unlink()

    def test_algorithm_guard_rejects_unauthenticated_or_sha1_mgf(self):
        d.checked_algorithms(ALGORITHMS)
        for bad in [ALGORITHMS.replace(b'aes-256-gcm', b'aes-256-cbc'),
                    ALGORITHMS.replace(b'authEnvelopedData', b'envelopedData'),
                    ALGORITHMS.replace(b'OBJECT :mgf1\nOBJECT :sha256', b'OBJECT :mgf1\nOBJECT :sha1')]:
            with self.assertRaises(ValueError):
                d.checked_algorithms(bad)

    def test_failed_encryption_removes_partial_ciphertext(self):
        output = self.root / 'partial.cms'
        def rejected(args):
            output.write_bytes(b'partial')
            return subprocess.CompletedProcess(args, 1, b'', b'private-control-sentinel')
        with patch.object(d, 'command', side_effect=rejected), self.assertRaises(ValueError):
            d.crypto(Path('openssl'), Path('recipient'), Path('owned'), output)
        self.assertFalse(output.exists())

    def test_public_certificate_real_cms_control(self):
        choices = [Path(r'C:\Program Files\Git\usr\bin\openssl.exe'),
                   Path(r'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'),
                   Path('/opt/homebrew/bin/openssl')]
        executable = next((p for p in choices if p.is_file()), None)
        self.assertIsNotNone(executable, 'reviewed OpenSSL implementation absent')
        plain = self.root / 'synthetic'
        plain.write_bytes(b'owned public-certificate encryption control')
        d.crypto(executable, ROOT / '.github/windows-focused-recipient-public.pem', plain, self.root / 'control.cms')
        self.assertNotIn(plain.read_bytes(), (self.root / 'control.cms').read_bytes())

    def test_raw_supervisor_stdout_is_private(self):
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(d, 'PRIVATE', self.root), contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = d.private_supervise([sys.executable, '-c', "print('private-control-sentinel')"], 'owned', 5)
        self.assertEqual(code, 0)
        self.assertIn('private-control-sentinel', (self.root / 'owned-output.log').read_text())
        self.assertNotIn('private-control-sentinel', output.getvalue() + errors.getvalue())
        workflow = (ROOT / '.github/workflows/windows-current-foundation-focused.yml').read_text()
        self.assertIn('1> focused-console-private/controller.log', workflow)
        self.assertIn('path: focused-safe/', workflow)
        self.assertNotIn('windows-*.log', workflow)


if __name__ == '__main__':
    unittest.main(verbosity=2)
