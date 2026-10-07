"""Shared file integrity and process helpers for portable release gates."""
from __future__ import annotations
import hashlib, json, os, platform, signal, subprocess, tempfile
from pathlib import Path
import re
ROOT = Path(__file__).resolve().parents[1]
HEX = re.compile(r'^[0-9a-f]{64}$')
SHA = re.compile(r'^[0-9a-f]{40}$')
def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else digest_stream(stream)

def digest_stream(stream):
    h = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()

def write_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent, delete=False) as f:
        json.dump(value, f, indent=2, sort_keys=True); f.write('\n'); temp = Path(f.name)
    os.replace(temp, path)

def host():
    return {'system': platform.system().lower(), 'architecture': platform.machine().lower()}

def clean_environment():
    env = {k:v for k,v in os.environ.items() if not k.startswith(('RIGHTCLICK_', 'SWIFT_', 'DYLD_', 'LD_'))}
    if os.name == 'nt':
        system = env.get('SystemRoot', r'C:\Windows')
        env['PATH'] = system + r'\System32;' + system
    else: env['PATH'] = '/usr/bin:/bin'
    return env

def stop_tree(p):
    if p.poll() is not None: return
    if os.name == 'nt':
        taskkill = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/taskkill.exe'
        subprocess.run([str(taskkill), '/PID', str(p.pid), '/T', '/F'], capture_output=True, timeout=15)
    else:
        try: os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError: pass
    p.wait(timeout=15)
