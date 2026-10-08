#!/usr/bin/env python3
"""Read-only native A/B diagnostics; never prints host paths or environment values."""
from pathlib import Path, PureWindowsPath
import argparse, hashlib, json, os, re, subprocess, sys, tempfile, threading, time

SOURCE = 'f07db3725e185babd7abd6e55942c5e616b01eac'
SOURCES_TREE = 'fd3f153c2a1e195e7766a40a1585f6526c73794a'
INPUTS = ['Package.swift', 'Package.resolved', 'LICENSE', 'Sources', 'Tests',
          'Vendor', 'fixtures', 'packaging', 'scripts']
ARGUMENTS = ['-latest', '-products', '*', '-requires',
             'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath']
CONTEXT_NAMES = ('ALLUSERSPROFILE', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)')
KNOWN_LOCATION_ROLES = {'all_user_application_data': 'ALLUSERSPROFILE',
    'machine_application_data': 'ProgramData', 'native_program_files': 'ProgramFiles',
    'x86_program_files': 'ProgramFiles(x86)'}
MAX_OUTPUT = 32_768


def digest(data):
    return hashlib.sha256(data).hexdigest()


def selected_host_context(environment):
    # Read only these nonsecret names, without copying or enumerating credentials.
    selected = {}
    for name in ('SystemRoot', *CONTEXT_NAMES):
        value = environment.get(name)
        if value is not None:
            selected[name] = value
    return selected


def unsafe_path(path):
    path = path.absolute()  # Keep redirecting ancestor boundaries visible.
    return any(p.is_symlink() or getattr(p, 'is_junction', lambda: False)()
               for p in (path, *path.parents))


def lookup(ambient, name):
    values = [value for key, value in ambient.items() if key.casefold() == name.casefold()]
    if len(set(values)) > 1:
        raise ValueError('ambiguous_host_context')
    return values[0] if values else None


def host_path(value):
    if (not isinstance(value, str) or not 0 < len(value) <= 4096
            or any(c in value for c in ('\x00', '\r', '\n', '"'))
            or not re.match(r'^[A-Za-z]:[\\/]', value)
            or not PureWindowsPath(value).is_absolute()):
        raise ValueError('host_context_path')
    return value


def profiles(ambient, temporary):
    # Preserve the production baseline's three keys. An explicit installer
    # context is a diagnostic counterfactual, never inherited broad authority.
    minimum = {'SystemRoot': host_path(lookup(ambient, 'SystemRoot') or r'C:\Windows'),
               'TEMP': host_path(temporary), 'TMP': host_path(temporary)}
    additional = {}
    presence = {}
    for name in CONTEXT_NAMES:
        value = lookup(ambient, name)
        presence[name] = value is not None
        if value is not None:
            additional[name] = host_path(value)
    if sum(len(k) + len(v) + 2 for k, v in additional.items()) > 8192:
        raise ValueError('host_context_budget')
    return minimum, {**minimum, **additional}, presence


def isolated_sequence(minimum, context):
    if (set(minimum) != {'SystemRoot', 'TEMP', 'TMP'}
            or set(context) - set(minimum) - set(CONTEXT_NAMES)):
        raise ValueError('closed_known_location_context')
    sequence = [('minimal_before', minimum)]
    for role, name in KNOWN_LOCATION_ROLES.items():
        addition = {name: context[name]} if name in context else {}
        sequence.append(('known_location_' + role, {**minimum, **addition}))
    return [*sequence, ('bounded_installer_context', context), ('minimal_after', minimum)]


def valid_absolute_selection(sample):
    flags = sample['validation']
    return (sample['outcome'] == 'completed' and sample['exitCode'] == 0
        and sample['outputDrainCompleted'] and not flags['empty'] and flags['isAbsolute']
        and not any(flags[key] for key in ('containsQuote', 'containsEmbeddedLF', 'startsUTF8BOM')))


def validation(data):
    # Match the existing query's text boundary while keeping raw bytes private.
    value = data.decode('utf-8', 'replace').strip()
    return {'empty': not value, 'isAbsolute': PureWindowsPath(value).is_absolute(),
            'containsQuote': '"' in value, 'containsEmbeddedLF': '\n' in value,
            'startsUTF8BOM': data.startswith(b'\xef\xbb\xbf')}


def sample(executable, arguments, environment, deadline=5, maximum=MAX_OUTPUT):
    began = time.monotonic()
    data = bytearray()
    counters = {'observed': 0, 'overBudget': False, 'readError': None}
    finished = threading.Event()
    lock = threading.Lock()
    process = None
    outcome = 'launch_failed'
    exit_code = None
    try:
        process = subprocess.Popen([str(executable), *arguments], env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        def consume():
            try:
                while chunk := os.read(process.stdout.fileno(), 4096):
                    with lock:
                        counters['observed'] += len(chunk)
                        if len(data) + len(chunk) > maximum:
                            counters['overBudget'] = True
                        elif not counters['overBudget']:
                            data.extend(chunk)
            except Exception as error:
                counters['readError'] = type(error).__name__
            finally:
                finished.set()
        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        outcome = 'completed'
        while process.poll() is None:
            if counters['overBudget']:
                outcome = 'output_budget'
                process.kill()
                break
            if time.monotonic() - began >= deadline:
                outcome = 'deadline'
                process.kill()
                break
            time.sleep(0.002)
        process.wait(timeout=2)
        reader.join(timeout=1)
        exit_code = process.returncode
        if not finished.is_set() or counters['readError'] is not None:
            outcome = 'output_drain_failure'
        elif counters['overBudget']:
            outcome = 'output_budget'
        elif outcome == 'completed' and exit_code != 0:
            outcome = 'child_failed'
    except Exception:
        outcome = 'launch_failed'
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            if finished.is_set() and process.stdout is not None:
                process.stdout.close()
    with lock:
        retained = bytes(data)
        observed = counters['observed']
    return {'outcome': outcome, 'exitCode': exit_code, 'stdoutBytes': observed,
            'retainedBytes': len(retained), 'stdoutSHA256': digest(retained),
            'elapsedMilliseconds': round((time.monotonic() - began) * 1000, 3),
            'outputDrainCompleted': finished.is_set(), 'validation': validation(retained)}


def git(*args):
    result = subprocess.run(['git', *args], capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError('source_provenance')
    return result.stdout


def main(output):
    report = {'status': 'STARTED', 'diagnosticOnly': True,
              'runtimeEnvironmentChanged': False, 'providerExecutionClaimed': False,
              'rawEnvironmentPathsOrQueryOutputPublished': False}
    code = 125
    try:
        if os.name != 'nt' or sys.version_info[:2] != (3, 12):
            raise ValueError('native_toolchain')
        report['physicalHead'] = git('rev-parse', 'HEAD').decode().strip()
        if (git('rev-parse', SOURCE + ':Sources').decode().strip() != SOURCES_TREE
                or subprocess.run(['git', 'diff', '--quiet', SOURCE, '--', *INPUTS], capture_output=True, timeout=30).returncode
                or git('ls-files', '--others', '--exclude-standard', '--', *INPUTS)):
            raise ValueError('source_inputs')
        report.update(reviewedSource=SOURCE, runtimeSourcesTree=SOURCES_TREE,
                      packagedInputsEqualReviewedSource=True)
        ambient = selected_host_context(os.environ)
        minimum, context, presence = profiles(ambient, tempfile.gettempdir())
        programs = host_path(lookup(ambient, 'ProgramFiles(x86)') or r'C:\Program Files (x86)')
        executable = Path(programs) / 'Microsoft Visual Studio' / 'Installer' / 'vswhere.exe'
        if unsafe_path(executable) or not executable.is_file() or executable.stat().st_size > 8 * 1024 * 1024:
            raise ValueError('installed_query_binary')
        before = digest(executable.read_bytes())
        report.update(installedQuerySHA256=before,
                      fixedArgumentsSHA256=digest(json.dumps(ARGUMENTS, separators=(',', ':')).encode()),
                      explicitContextPresence=presence,
                      transport='PythonNativeSubprocessSameAbsoluteBinaryAndArguments',
                      productionFoundationInvocationRepaired=False)
        samples = []
        for name, environment in isolated_sequence(minimum, context):
            measured = sample(executable, ARGUMENTS, environment)
            samples.append({'profile': name, **measured})
        report['samples'] = samples
        if digest(executable.read_bytes()) != before:
            raise ValueError('installed_query_binary_changed')
        report['installedQueryUnchanged'] = True
        a, b, c = samples[0], samples[-2], samples[-1]
        valid = lambda x: (x['outcome'] == 'completed' and x['exitCode'] == 0
                            and x['outputDrainCompleted'])
        report['minimalProfilesBothEmpty'] = valid(a) and valid(c) and a['validation']['empty'] and c['validation']['empty']
        report['boundedContextReturnsAbsoluteSelection'] = valid_absolute_selection(b)
        report['singleKnownLocationResults'] = {
            role: {'contextNamePresent': presence[name],
                   'returnsAbsoluteSelection': valid_absolute_selection(samples[index + 1])}
            for index, (role, name) in enumerate(KNOWN_LOCATION_ROLES.items())}
        report['isolationMatrixMeasured'] = True
        report['status'] = ('ENVIRONMENT_CONTEXT_DIFFERENCE_OBSERVED' if report['minimalProfilesBothEmpty']
            and report['boundedContextReturnsAbsoluteSelection'] else 'NO_VALIDATED_CONTEXT_DIFFERENCE')
        report['scope'] = 'ReadOnlyDiagnosticNoProductionPromotionNoProviderGREEN'
        code = 0
    except Exception as error:
        report['status'] = 'FAILED_CLOSED'
        report['errorType'] = type(error).__name__
        if type(error) is ValueError and re.fullmatch('[a-z_]{1,64}', str(error)):
            report['errorLabel'] = str(error)
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    except Exception as error:
        print(json.dumps({'status': 'REPORT_WRITE_FAILED_CLOSED', 'errorType': type(error).__name__}, separators=(',', ':')))
        return 125
    print(json.dumps({'status': report['status'], 'diagnosticOnly': True}, separators=(',', ':')))
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    raise SystemExit(main(options.output))
