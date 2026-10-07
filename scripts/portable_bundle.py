"""Integrity-checked, fail-closed candidate bundles. Does not publish releases."""
from __future__ import annotations
import hashlib, json, os, platform, re, shutil, stat, subprocess, tempfile, zipfile
from pathlib import Path, PurePosixPath
from portable_common import ROOT, HEX, SHA, sha256, host, write_json

def safe_name(name):
    if not name or any(ord(c)<32 for c in name) or '\\' in name or ':' in name or len(name)>512: raise ValueError('Unsafe archive path')
    p = PurePosixPath(name)
    if p.is_absolute() or any(x in ('','.', '..') for x in name.split('/')): raise ValueError('Unsafe archive path')
    if any(x.endswith((' ','.')) for x in p.parts): raise ValueError('Ambiguous archive path')
    if any(re.fullmatch(r'(?i)(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?',x) for x in p.parts): raise ValueError('Reserved archive path')
    return p

def verify_bundle(archive, expected, destination):
    archive = Path(archive); destination = Path(destination)
    if not HEX.fullmatch(expected) or sha256(archive) != expected: raise ValueError('Archive checksum mismatch')
    if destination.exists() or destination.is_symlink(): raise ValueError('Extraction destination already exists')
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist(); names = set(); folded = set()
        if not 1 <= len(infos) <= 2048 or sum(i.file_size for i in infos)>1024**3: raise ValueError('Archive limits exceeded')
        for i in infos:
            safe_name(i.filename)
            if i.filename in names or i.filename.casefold() in folded: raise ValueError('Duplicate archive path')
            mode = stat.S_IFMT(i.external_attr >> 16)
            if mode not in (0,stat.S_IFREG) or i.flag_bits & 1: raise ValueError('Nonregular or encrypted member')
            names.add(i.filename); folded.add(i.filename.casefold())
        if 'manifest.json' not in names or z.getinfo('manifest.json').file_size > 1_048_576: raise ValueError('Missing or excessive manifest')
        for name in names:
            if any(str(parent).casefold() in folded for parent in PurePosixPath(name).parents if str(parent)!='.'):
                raise ValueError('Conflicting file and directory path')
        manifest = json.loads(z.read('manifest.json'))
        if not isinstance(manifest,dict) or not isinstance(manifest.get('files'),dict): raise ValueError('Invalid manifest shape')
        if manifest.get('schema') != 1 or not SHA.fullmatch(manifest.get('sourceSHA','')): raise ValueError('Invalid manifest')
        if set(manifest['files']) != names-{'manifest.json'}: raise ValueError('Manifest file set mismatch')
        for name,expected_hash in manifest['files'].items():
            if not HEX.fullmatch(expected_hash) or hashlib.sha256(z.read(name)).hexdigest() != expected_hash: raise ValueError('Member checksum mismatch: '+name)
        binary = str(safe_name(manifest['executable']))
        if binary not in manifest['files'] or manifest['files'][binary] != manifest['binarySHA256']: raise ValueError('Executable binding mismatch')
        destination.parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=destination.parent,prefix='rightclick-extract-') as tmp:
            staged = Path(tmp)/'bundle'; staged.mkdir()
            for i in infos:
                target = staged/i.filename; target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(z.read(i.filename)); target.chmod(0o755 if i.filename==binary else 0o644)
            os.replace(staged,destination)
    return manifest

def bundle(binary, report_file, output, source):
    binary = Path(binary).resolve(strict=True); report_file = Path(report_file)
    if not SHA.fullmatch(source): raise ValueError('Expected full source SHA')
    checkout = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True,timeout=15).strip()
    dirty = subprocess.check_output(['git','status','--porcelain','--untracked-files=no'],cwd=ROOT,text=True,timeout=15).strip()
    if checkout != source or dirty: raise ValueError('Bundle must be created from its exact clean source commit')
    report = json.loads(report_file.read_text())
    if report.get('result')!='PASS' or report.get('sourceSHA')!=source or report.get('binarySHA256')!=sha256(binary): raise ValueError('Only an accepted exact binary can be bundled')
    if report.get('host')!=host() or not report.get('samples'): raise ValueError('Host or acceptance mismatch')
    version = subprocess.check_output([str(binary),'--version'],text=True,timeout=15).strip()
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',version): raise ValueError('Unexpected binary version')
    target = json.loads(subprocess.check_output(['swift','-print-target-info'],text=True,timeout=30))
    name = 'rightclick-'+version+'-'+host()['system']+'-'+host()['architecture']+'-'+source[:12]+'-candidate'
    output = Path(output); output.mkdir(parents=True,exist_ok=True)
    archive = output/(name+'.zip')
    if archive.exists(): raise ValueError('Never overwrite an existing bundle')
    with tempfile.TemporaryDirectory(prefix='rightclick-bundle-') as tmp:
        work = Path(tmp); executable = 'bin/'+('rightclick.exe' if os.name=='nt' else 'rightclick')
        (work/'bin').mkdir(); shutil.copyfile(binary,work/executable)
        (work/'LICENSE').write_bytes((ROOT/'LICENSE').read_bytes())
        licence_root = ROOT/'packaging/ThirdPartyLicenses'
        for p in licence_root.rglob('*'):
            if p.is_file() and not p.is_symlink():
                dst=work/'licenses'/p.relative_to(licence_root); dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(p.read_bytes())
        (work/'licenses/MCP-LICENSE').write_bytes((ROOT/'Vendor/swift-sdk/LICENSE').read_bytes())
        roots = [Path(p) for p in target['paths'].get('runtimeLibraryPaths',[])]
        swift = Path(shutil.which('swift')).resolve()
        if platform.system()!='Darwin':
            licence = swift.parent.parent/'share/swift/LICENSE.txt'
            if not licence.is_file(): raise ValueError('Swift runtime redistribution licence missing')
            (work/'licenses/SWIFT-RUNTIME-LICENSE.txt').write_bytes(licence.read_bytes())
            if os.name=='nt':
                if os.environ.get('SDKROOT'): roots.append(Path(os.environ['SDKROOT'])/'usr/bin')
                roots.extend([r/'bin' for r in list(roots)])
            copied = {}
            for root in roots:
                if not root.is_dir(): continue
                for p in sorted(root.glob('*.dll' if os.name=='nt' else '*.so*')):
                    if not p.is_file(): continue
                    data=p.read_bytes(); h=hashlib.sha256(data).hexdigest()
                    if p.name.casefold() in copied:
                        if copied[p.name.casefold()]!=h: raise ValueError('Conflicting runtime library: '+p.name)
                        continue
                    copied[p.name.casefold()]=h
                    dst=work/('bin' if os.name=='nt' else 'lib')/p.name
                    dst.parent.mkdir(parents=True,exist_ok=True); dst.write_bytes(data)
            if not copied: raise ValueError('No redistributable Swift runtime found')
        (work/'acceptance.json').write_bytes(report_file.read_bytes())
        instructions='RIGHTCLICK SOURCE CANDIDATE — NOT A PUBLISHED RELEASE\n\nRun bin/rightclick platform --json, then bin/rightclick connect. Use rightclick.exe on Windows.\nKeep the complete extracted directory together. This bundle is architecture-specific.\nLinux requires compatible glibc/system curl and XML libraries; Windows requires the Microsoft Visual C++ runtime.\nChecksums establish integrity, not publisher authenticity. macOS notarization is not claimed.\nNo settings or credentials are changed by extraction or connect.\n'
        (work/'INSTALL.txt').write_text(instructions)
        files={p.relative_to(work).as_posix():sha256(p) for p in work.rglob('*') if p.is_file()}
        manifest={'schema':1,'sourceSHA':source,'binarySHA256':sha256(binary),'version':version,'host':host(),'targetTriple':target['target']['triple'],'executable':executable,'status':'candidate','files':files}
        write_json(work/'manifest.json',manifest)
        with zipfile.ZipFile(archive,'x',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
            for p in sorted(work.rglob('*')):
                if not p.is_file(): continue
                rel=p.relative_to(work).as_posix(); info=zipfile.ZipInfo(rel,(2026,1,1,0,0,0))
                info.create_system=3; info.external_attr=(stat.S_IFREG | (0o755 if rel==executable else 0o644))<<16
                info.compress_type=zipfile.ZIP_DEFLATED; z.writestr(info,p.read_bytes())
        checksum=sha256(archive); (output/(name+'.sha256')).write_text(checksum+'  '+archive.name+'\n')
    return {'archive':str(archive),'sha256':checksum,'sourceSHA':source,'binarySHA256':sha256(binary)}

def verify_sdk(root=None):
    root = Path(root or ROOT/'Vendor/swift-sdk')
    metadata = json.loads((root/'UPSTREAM.json').read_text())
    if metadata.get('revision') != 'a0ae212ebf6eab5f754c3129608bc5557637e605':
        raise ValueError('Unexpected MCP SDK revision')
    actual = {p.relative_to(root).as_posix() for p in (root/'Sources/MCP').rglob('*') if p.is_file()}
    if actual != set(metadata['files']): raise ValueError('SDK production file-set drift')
    changed = []
    for name,entry in metadata['files'].items():
        p = root/str(safe_name(name))
        if p.is_symlink(): raise ValueError('SDK symlink is not permitted')
        data = p.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry['patched']: raise ValueError('SDK byte drift: '+name)
        if entry['upstream'] != entry['patched']:
            changed.append(name)
            if data.count(b'#if canImport(EventSource)') != 2: raise ValueError('Unexpected SDK change')
            restored = data.replace(b'#if canImport(EventSource)',b'#if !os(Linux)')
            if hashlib.sha256(restored).hexdigest() != entry['upstream']: raise ValueError('SDK patch exceeds availability guards')
    if changed != ['Sources/MCP/Base/Transports/HTTPClientTransport.swift']: raise ValueError('Unexpected SDK patch set')
    if sha256(root/'Package.swift') != metadata['manifest_sha256']: raise ValueError('SDK manifest drift')
    if sha256(root/'LICENSE') != metadata['license_sha256']: raise ValueError('SDK licence drift')
    return {'result':'PASS','revision':metadata['revision'],'production_files':len(actual),'changed_files':changed}
