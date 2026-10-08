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
import windows_compiler_search_diagnostic as d

EXPECTED = set(json.loads((ROOT / '.github/windows-compiler-search-one-name.json').read_text()))
BASELINE = set(json.loads((ROOT / '.github/windows-compiler-search-shipping702-baseline.json').read_text())['names'])
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


def compiler_log():
    rows = []
    for i, profile in enumerate(["isolatedBefore", "explicitSystemSearch", "isolatedAfter"]):
        green = i == 1
        rows.append("TrustedHostContext compilerProfile comparison=nativeSearchRole profile=" + profile +
            " index=" + str(i) + " outcome=" + ("completed" if green else "childFailed") +
            " started=true exit=" + ("0" if green else "2") + " stdoutBytes=" + ("0" if green else "222") +
            " elapsedMilliseconds=500.0 freshPE=" + ("true" if green else "false") +
            " outputSHA256=" + ("a"*64 if green else "none") +
            " stableOutput=true unchangedInputs=true parentAndStdoutClosed=true ownedGroupClosureClaimed=false")
    rows.append("TrustedHostContext compilerSearchClosed success=false,true,false freshPE=false,true,false sameArguments=true unchangedInputs=true searchRoleCurrent=true defaultIsolationRestored=true diagnosticOnly=true")
    return "\n".join(rows)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rightclick-focused-control-')
        self.root = Path(self.temp.name).resolve()

    def tearDown(self):
        self.temp.cleanup()

    def test_all_702_baseline_names_required_even_with_703_total(self):
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

    def test_filter_selects_exact_one_native_diagnostic_and_rejects_similar_class_names(self):
        self.assertEqual({name for name in (BASELINE | EXPECTED) if re.search(d.FILTER, name)}, EXPECTED)
        similar = 'RightClickCoreTests.RCIRInvocationBindingTests/testOnlyHostTaskIdentityCanVerifyMatchingObservation'
        self.assertIn(similar, BASELINE)
        self.assertIsNone(re.search(d.FILTER, similar))
        self.assertIsNone(re.search(d.FILTER,
            'RightClickCoreTests.UnrelatedInvocationBindingTests/testExtra'))

    def test_complete_one_native_diagnostic_and_failure_are_distinct(self):
        result = d.execution(log(), EXPECTED)
        self.assertEqual((result['passes'], result['failures'], result['skips']), (1, 0, 0))
        failed = d.execution(log().replace(' passed (', ' failed (', 1), EXPECTED)
        self.assertEqual((failed['passes'], failed['failures']), (0, 1))
        self.assertTrue(result['swiftTestingZeroSuiteObserved'])

    def test_truncated_duplicate_or_unselected_completion_rejected(self):
        good = log()
        for bad in [good.splitlines()[2:], good + good,
                    good.replace('testSameOwnedCompilerIsolatedSystem32Isolated', 'testUnselected')]:
            with self.assertRaises(ValueError):
                d.execution('\n'.join(bad) if isinstance(bad, list) else bad, EXPECTED)

    def test_skipped_case_never_counted_as_pass(self):
        result = d.execution(log().replace(' passed (', ' skipped (', 1), EXPECTED)
        self.assertEqual((result['passes'], result['skips']), (0, 1))

    def test_archive_whitelist_hashes_exact_retained_bytes(self):
        file = self.root / 'owned.json'
        file.write_bytes(b'{"synthetic":true}\n')
        output = self.root / 'owned.tar'
        result = d.archive([('build-output.log', file)], output)
        with tarfile.open(output) as tar:
            item = tar.getmember('build-output.log')
            self.assertEqual((item.mode, item.uid, item.gid), (0o600, 0, 0))
            self.assertEqual(tar.extractfile(item).read(), file.read_bytes())
        self.assertEqual(result['build-output.log']['sha256'], d.digest(file.read_bytes()))
        with self.assertRaises(ValueError):
            d.archive([('signer.raw', file)], self.root / 'rejected.tar')

    def test_archive_size_and_total_budget_reject(self):
        file = self.root / 'owned.json'
        file.write_bytes(b'abcde')
        with patch.object(d, 'MAX_FILE', 4), self.assertRaises(ValueError):
            d.archive([('build-output.log', file)], self.root / 'one.tar')
        with patch.object(d, 'MAX_TOTAL', 9), self.assertRaises(ValueError):
            d.archive([('build-output.log', file), ('discovery-output.log', file)], self.root / 'two.tar')

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
                d.archive([('build-output.log', alias / file.name)], self.root / 'no.tar')
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

    def test_thin_capsule_rejects_all_legacy_trust_exports(self):
        file = self.root / 'owned'
        file.write_bytes(b'synthetic')
        for name in ['runtime-records.json', 'trust-results.json', 'key-0-public.raw']:
            with self.assertRaisesRegex(ValueError, 'owned_file_type'):
                d.archive([(name, file)], self.root / (name + '.tar'))

    def test_compiler_aba_observation_closed_scalars_and_consistency(self):
        good = compiler_log()
        result = d.compiler_search_observation(good + " private=private-control-sentinel")
        self.assertTrue(result["completeObservation"])
        self.assertFalse(result["shippingCompilerAcceptanceClaimed"])
        self.assertEqual([p["freshPE"] for p in result["profiles"]], [False, True, False])
        self.assertNotIn("private-control-sentinel", json.dumps(result))
        for bad in [good.replace("stdoutBytes=222", "stdoutBytes=17000", 1),
                    good.replace("exit=2", "exit=0", 1),
                    good.replace("elapsedMilliseconds=500.0", "elapsedMilliseconds=33000.0", 1),
                    good.replace("outputSHA256=" + "a"*64, "outputSHA256=none"),
                    good.replace("stableOutput=true", "stableOutput=false", 1),
                    good.replace("ownedGroupClosureClaimed=false", "ownedGroupClosureClaimed=true", 1),
                    good.replace("profile=isolatedBefore", "profile=private-label", 1),
                    good.replace("success=false,true,false", "success=true,true,false")]:
            with self.assertRaises(ValueError): d.compiler_search_observation(bad)
        for bad in [good.replace("defaultIsolationRestored=true", "defaultIsolationRestored=false"),
                    good.replace("searchRoleCurrent=true", "searchRoleCurrent=false"),
                    "\n".join(good.splitlines()[1:]), good + "\n" + good.splitlines()[0]]:
            self.assertFalse(d.compiler_search_observation(bad)["completeObservation"])

    def test_all_closed_natural_failures_are_observation_without_acceptance(self):
        observed = compiler_log().replace("outcome=completed started=true exit=0 stdoutBytes=0", "outcome=childFailed started=true exit=2 stdoutBytes=222").replace("freshPE=true outputSHA256=" + "a"*64, "freshPE=false outputSHA256=none").replace("success=false,true,false freshPE=false,true,false", "success=false,false,false freshPE=false,false,false")
        result = d.compiler_search_observation(observed)
        self.assertTrue(result["completeObservation"])
        self.assertFalse(result["shippingCompilerAcceptanceClaimed"])

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
        workflow = (ROOT / '.github/workflows/windows-compiler-search-role.yml').read_text()
        self.assertIn('1> focused-console-private/controller.log', workflow)
        self.assertIn('path: focused-safe/', workflow)
        self.assertNotIn('windows-*.log', workflow)


if __name__ == '__main__':
    unittest.main(verbosity=2)
