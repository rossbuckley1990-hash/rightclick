#!/usr/bin/env python3
"""CI-only full native XCTest diagnosis; never a SwiftPM-pass replacement."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys

from windows_test_supervisor import supervise

RELEASE_SOURCE = '39b37afbcc288eb07c5fe341b506f35ebb77e361'
EXPECTED_COUNT = 666
TRIPLE = 'x86_64-unknown-windows-msvc'
SOURCE_INPUTS = ['Package.swift', 'Package.resolved', 'LICENSE', 'Sources', 'Tests',
                 'Vendor', 'fixtures', 'packaging', 'scripts']
NAME = re.compile(r'^RightClick\w+Tests\.\w+/\w+$')


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def discovery_names(text):
    names = [line.strip() for line in text.splitlines() if NAME.fullmatch(line.strip())]
    if len(names) != EXPECTED_COUNT or len(set(names)) != EXPECTED_COUNT:
        raise ValueError('discovery_count')
    return set(names)


def dump_names(data):
    """Parse the actual XCTest TestListing schema, rejecting duplicates/unknowns."""
    if not isinstance(data, dict) or not isinstance(data.get('tests'), list):
        raise ValueError('inventory_schema')
    names = []
    for suite in data['tests']:
        if not isinstance(suite, dict) or not isinstance(suite.get('tests'), list):
            raise ValueError('inventory_suite')
        for case in suite['tests']:
            if not isinstance(case, dict) or not isinstance(case.get('tests'), list):
                raise ValueError('inventory_case')
            for test in case['tests']:
                if not isinstance(test, dict):
                    raise ValueError('inventory_test_schema')
                name = case.get('name', '') + '/' + test.get('name', '')
                if not NAME.fullmatch(name) or 'tests' in test:
                    raise ValueError('inventory_test')
                names.append(name)
    if len(names) != EXPECTED_COUNT or len(set(names)) != EXPECTED_COUNT:
        raise ValueError('inventory_count')
    return set(names)


def required_dll_paths(sdk_root):
    """Match SwiftPM6.2 UserToolchain Windows x86_64 path derivation."""
    platform = sdk_root.parent.parent.parent
    info_path = platform / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())['DefaultProperties']
    versions = [info['XCTEST_VERSION'], info['SWIFT_TESTING_VERSION']]
    if any(not isinstance(v, str) or not re.fullmatch(r'[A-Za-z0-9.+-]{1,80}', v)
           for v in versions):
        raise ValueError('library_version')
    library = platform / 'Developer' / 'Library'
    xctest = library / ('XCTest-' + versions[0]) / 'usr'
    xctest_bin = xctest / 'bin64'
    if not xctest_bin.is_dir():
        xctest_bin = xctest / 'bin'  # SwiftPM's old-layout migration fallback.
    testing_bin = library / ('Testing-' + versions[1]) / 'usr' / 'bin64'
    paths = [testing_bin, xctest_bin]  # SwiftPM prepends XCTest, then Testing.
    for path, dll in zip(paths, ['Testing.dll', 'XCTest.dll']):
        if not (path / dll).is_file():
            raise FileNotFoundError('required_dll')
    return paths, info_path


def assert_x64_pe(binary):
    with binary.open('rb') as stream:
        if stream.read(2) != b'MZ':
            raise ValueError('pe_signature')
        stream.seek(0x3c)
        offset = struct.unpack('<I', stream.read(4))[0]
        stream.seek(offset)
        if stream.read(4) != b'PE\0\0' or stream.read(2) != b'\x64\x86':
            raise ValueError('pe_machine')


def preflight():
    if os.name != 'nt':
        raise RuntimeError('native_windows_required')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    subprocess.check_call(['git', 'diff', '--quiet', RELEASE_SOURCE, '--', *SOURCE_INPUTS])
    if subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '--', *SOURCE_INPUTS]):
        raise ValueError('untracked_source_input')
    if '_SWIFTPM_SKIP_TESTS_LIST' in os.environ:
        raise ValueError('skip_override_present')
    # This frozen package declares only XCTest tests. Refuse silently extending
    # the claim if Swift Testing declarations have entered its source closure.
    testing_declarations = re.compile(r'\bimport\s+Testing\b|@(?:Test|Suite)\b')
    for path in Path('Tests').rglob('*.swift'):
        if testing_declarations.search(path.read_text(encoding='utf-8')):
            raise ValueError('swift_testing_declaration')
    binary = (Path('.build') / TRIPLE / 'debug' / 'rightclick-mcpPackageTests.xctest').resolve(strict=True)
    assert_x64_pe(binary)
    dll_paths, info_path = required_dll_paths(Path(os.environ['SDKROOT']))
    path_key = next(key for key in os.environ if key.upper() == 'PATH')
    os.environ[path_key] = os.pathsep.join(map(str, dll_paths)) + os.pathsep + os.environ[path_key]
    os.environ['NO_COLOR'] = '1'
    return {
        'source': source, 'releaseSource': RELEASE_SOURCE, 'sourceInputDiffEmpty': True,
        'binary': str(binary), 'binarySHA256': sha256(binary), 'target': TRIPLE,
        'requiredDLLDirectories': list(map(str, dll_paths)),
        'platformInfoSHA256': sha256(info_path),
        'swiftpmSkipTestsListAbsent': True, 'swiftTestingDeclarationsAbsent': True,
        'argumentsRetained': False, 'unrelatedEnvironmentValuesRetained': False,
    }


def completed_xctest(text, expected):
    # The native reporter uses bare case names; refuse ambiguous module mapping.
    by_short = {name.split('.', 1)[1].replace('/', '.', 1): name for name in expected}
    if len(by_short) != len(expected):
        raise ValueError('ambiguous_reporter_names')
    starts = re.findall(r"^Test Case '([^']+)' started", text, re.MULTILINE)
    finishes = re.findall(r"^Test Case '([^']+)' (passed|skipped|failed) \(", text, re.MULTILINE)
    if len(starts) != EXPECTED_COUNT or set(starts) != set(by_short):
        raise ValueError('incomplete_starts')
    if len(finishes) != EXPECTED_COUNT or {name for name, _ in finishes} != set(by_short):
        raise ValueError('incomplete_finishes')
    if any(state == 'failed' for _, state in finishes):
        raise ValueError('test_failure')
    if not re.search(r'Executed 666 tests, with (?:\d+ tests? skipped and )?0 failures \(0 unexpected\)', text):
        raise ValueError('missing_full_summary')
    return {'started': len(starts), 'completed': len(finishes),
            'skipped': sum(state == 'skipped' for _, state in finishes), 'failures': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['inventory', 'full'])
    args = parser.parse_args()
    record_path = 'windows-direct-' + args.phase + '-summary.json'
    record = {'state': 'STARTED', 'originalSwiftPMRunID': 37699465385,
              'originalSwiftPMPassClaimed': False, 'phase': args.phase,
              'swiftpmSkipTestsListAbsent': '_SWIFTPM_SKIP_TESTS_LIST' not in os.environ}
    exit_code = 125
    try:
        metadata = preflight()
        record.update(metadata)
        write_json(record_path, record)
        expected = discovery_names(Path('windows-test-discovery.log').read_text(encoding='utf-8-sig'))
        binary = metadata['binary']
        if args.phase == 'inventory':
            code = supervise([binary, '--dump-tests-json'], 'windows-direct-inventory', 120, 10, True)
            if code:
                exit_code = code
                raise RuntimeError('inventory_process_failure')
            actual = dump_names(json.loads(Path('windows-direct-inventory-output.log').read_text(encoding='utf-8')))
            if actual != expected:
                raise ValueError('inventory_difference')
            record.update(inventoryNames=len(actual), uniqueInventoryNames=len(actual), inventoryEqualsDiscovery=True)
        else:
            inventory = json.loads(Path('windows-direct-inventory-summary.json').read_text())
            if inventory.get('state') != 'COMPLETED' or inventory.get('binarySHA256') != metadata['binarySHA256'] or inventory.get('source') != metadata['source']:
                raise ValueError('inventory_provenance')
            code = supervise([binary], 'windows-direct-xctest', 1440, 10, True)
            if code:
                exit_code = code
                raise RuntimeError('full_xctest_failure')
            record.update(xctest=completed_xctest(Path('windows-direct-xctest-output.log').read_text(encoding='utf-8'), expected))
            # Preserve the second full default library invocation, with no filter.
            code = supervise([binary, '--testing-library', 'swift-testing'], 'windows-direct-swift-testing', 120, 10, True)
            if code:
                exit_code = code
                raise RuntimeError('swift_testing_failure')
            text = Path('windows-direct-swift-testing-output.log').read_text(encoding='utf-8')
            if not re.search(r'Test run with 0 tests in 0 suites passed', text):
                raise ValueError('swift_testing_inventory_difference')
            record.update(swiftTestingCompleted=True, swiftTestingTests=0, fullUnfilteredLibrariesCompleted=True)
        if sha256(binary) != metadata['binarySHA256']:
            raise ValueError('binary_changed')
        record.update(state='COMPLETED', exitCode=0)
        exit_code = 0
    except Exception as error:
        record.update(state='FAILED', exitCode=exit_code, errorType=type(error).__name__)
        # No raw exception text, argv or environment contents enters metadata.
    finally:
        write_json(record_path, record)
        print('RIGHTCLICK-CI-DIRECT ' + json.dumps(record, separators=(',', ':')), flush=True)
    return exit_code


if __name__ == '__main__':
    raise SystemExit(main())
