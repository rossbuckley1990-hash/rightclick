#!/usr/bin/env python3
"""Meaningful fail-closed controls for the CI-only direct-native proof."""
import copy
import importlib.util
import plistlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import windows_direct_test as direct


def inventory():
    tests = [{'name': 'test' + str(i)} for i in range(direct.EXPECTED_COUNT)]
    return {'name': 'All tests', 'tests': [{'name': 'suite', 'tests': [
        {'name': 'RightClickCoreTests.SampleTests', 'tests': tests}]}]}


class DirectProofTests(unittest.TestCase):
    def test_actual_inventory_names_must_equal_discovery_and_remain_unique(self):
        data = inventory()
        names = direct.dump_names(data)
        self.assertEqual(len(names), direct.EXPECTED_COUNT)
        self.assertEqual(names, direct.discovery_names('\n'.join(sorted(names))))
        data['tests'][0]['tests'][0]['tests'][-1]['name'] = 'test0'
        with self.assertRaises(ValueError):
            direct.dump_names(data)

    def test_inventory_count_alone_cannot_mask_a_changed_case(self):
        original = direct.dump_names(inventory())
        changed = inventory()
        changed['tests'][0]['tests'][0]['tests'][-1]['name'] = 'testChanged'
        self.assertNotEqual(original, direct.dump_names(changed))
        with self.assertRaises(ValueError):
            direct.discovery_names('\n'.join(sorted(original)) + '\n' + sorted(original)[0])

    def test_unknown_inventory_nodes_and_missing_cases_fail_closed(self):
        for bad in ({}, {'tests': 'bad'}, {'tests': [{}]}):
            with self.assertRaises(ValueError):
                direct.dump_names(bad)
        data = inventory()
        data['tests'][0]['tests'][0]['tests'].pop()
        with self.assertRaises(ValueError):
            direct.dump_names(data)

    def test_full_completion_requires_every_start_finish_and_zero_failures(self):
        expected = direct.dump_names(inventory())
        starts = ["Test Case 'SampleTests.test%d' started at date" % i for i in range(direct.EXPECTED_COUNT)]
        finishes = ["Test Case 'SampleTests.test%d' passed (0.001 seconds)" % i for i in range(direct.EXPECTED_COUNT)]
        summary = 'Executed %d tests, with 0 failures (0 unexpected)' % direct.EXPECTED_COUNT
        full = '\n'.join(starts + finishes + [summary])
        self.assertEqual(direct.completed_xctest(full, expected)['completed'], direct.EXPECTED_COUNT)
        for bad in (full.replace(starts[-1], ''), full.replace(finishes[-1], ''),
                    full.replace(finishes[-1], finishes[-1].replace('passed', 'failed')),
                    full.replace(summary, 'Executed %d tests, with 0 failures (0 unexpected)' % (direct.EXPECTED_COUNT - 1)),
                    full.replace(finishes[-1], finishes[0])):
            with self.assertRaises(ValueError):
                direct.completed_xctest(bad, expected)

    def test_supported_platform_skips_are_counted_without_losing_cases(self):
        expected = direct.dump_names(inventory())
        rows = ["Test Case 'SampleTests.test%d' started" % i for i in range(direct.EXPECTED_COUNT)]
        rows += ["Test Case 'SampleTests.test%d' %s (0.001 seconds)" %
                 (i, 'skipped' if i < 35 else 'passed') for i in range(direct.EXPECTED_COUNT)]
        rows += ['Executed %d tests, with 35 tests skipped and 0 failures (0 unexpected)' % direct.EXPECTED_COUNT]
        self.assertEqual(direct.completed_xctest('\n'.join(rows), expected)['skipped'], 35)

    def test_reviewed_native_baseline_has_every_original_distinct_test(self):
        baseline = direct.baseline_names()
        self.assertEqual(len(baseline), 666)
        current = baseline | {'RightClickCoreTests.NewControlTests/testNewControl'}
        retained = direct.require_baseline_preserved(current, baseline)
        self.assertTrue(retained['baselineAllNamesPreserved'])
        self.assertEqual(retained['additionalTestNames'], 1)
        # Keeping the count constant by replacing a baseline test is still RED.
        changed = set(current)
        changed.remove(sorted(baseline)[0])
        changed.add('RightClickCoreTests.NewControlTests/testReplacement')
        self.assertEqual(len(changed), len(current))
        with self.assertRaises(ValueError):
            direct.require_baseline_preserved(changed, baseline)

    def test_original_native_baseline_pin_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'baseline.json'
            path.write_text('{"names": []}', encoding='utf-8')
            with self.assertRaises(ValueError):
                direct.baseline_names(path)

    def test_sdk_plist_selects_exact_installed_dll_directories_and_rejects_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            platform = Path(tmp)
            sdk = platform / 'Developer' / 'SDKs' / 'Windows.sdk'
            sdk.mkdir(parents=True)
            (platform / 'Info.plist').write_bytes(plistlib.dumps({'DefaultProperties': {
                'XCTEST_VERSION': '6.2', 'SWIFT_TESTING_VERSION': '6.2'}}))
            xctest = platform / 'Developer' / 'Library' / 'XCTest-6.2' / 'usr' / 'bin64'
            testing = platform / 'Developer' / 'Library' / 'Testing-6.2' / 'usr' / 'bin64'
            for path, dll in [(xctest, 'XCTest.dll'), (testing, 'Testing.dll')]:
                path.mkdir(parents=True)
                (path / dll).write_bytes(b'MZ')
            self.assertEqual(direct.required_dll_paths(sdk)[0], [testing, xctest])
            (testing / 'Testing.dll').unlink()
            with self.assertRaises(FileNotFoundError):
                direct.required_dll_paths(sdk)

    def test_runner_requires_actual_x64_pe_signature(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / 'runner.xctest'
            data = bytearray(256)
            data[:2] = b'MZ'
            data[0x3c:0x40] = struct.pack('<I', 128)
            data[128:134] = b'PE\0\0\x64\x86'
            binary.write_bytes(data)
            direct.assert_x64_pe(binary)
            data[132:134] = b'\x4c\x01'
            binary.write_bytes(data)
            with self.assertRaises(ValueError):
                direct.assert_x64_pe(binary)


if __name__ == '__main__':
    unittest.main(verbosity=2)
