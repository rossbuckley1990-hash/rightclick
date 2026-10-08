#!/usr/bin/env python3
"""Record exact checkout and native platform inputs before a CI proof."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--expected', default=os.environ.get('RIGHTCLICK_CI_SOURCE'))
args = parser.parse_args()
assert args.expected and re.fullmatch(r'[0-9a-f]{40}', args.expected), 'Exact expected source SHA required.'
def git(*arguments):
    return subprocess.check_output(['git', '-c', 'safe.directory=' + str(ROOT), *arguments], cwd=ROOT, timeout=30).decode().strip()
head = git('rev-parse', 'HEAD')
assert head == args.expected, 'Checked-out source differs from expected proof source.'
inputs = ['Package.swift', 'Package.resolved', 'Sources', 'Tests', 'Vendor', 'fixtures', 'scripts']
subprocess.run(['git', '-c', 'safe.directory=' + str(ROOT), 'diff', '--exit-code', 'HEAD', '--', *inputs], cwd=ROOT, check=True, timeout=30, stdout=subprocess.DEVNULL)
args.output.mkdir(parents=True, exist_ok=True)
(args.output / 'source-commit.txt').write_text(head + '\n')
(args.output / 'sources-tree.txt').write_text(git('rev-parse', 'HEAD:Sources') + '\n')
for name in ('Package.swift', 'Package.resolved'):
    (args.output / (name.lower().replace('.', '-') + '-sha256.txt')).write_text(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() + '\n')
record = {'head': head, 'nativeSystem': platform.system(), 'nativeMachine': platform.machine(),
          'swiftVersion': subprocess.check_output(['swift', '--version'], cwd=ROOT, timeout=30).decode().strip(),
          'inputGitObjects': {name: git('rev-parse', 'HEAD:' + name) for name in inputs},
          'trackedNativeInputsClean': True,
          'scope': 'Checkout/native platform input record only; not executable-image or provider acceptance.'}
(args.output / 'native-inputs.json').write_text(json.dumps(record, indent=2) + '\n')
