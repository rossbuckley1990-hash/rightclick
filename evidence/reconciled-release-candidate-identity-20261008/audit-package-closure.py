import hashlib, json, pathlib, re, subprocess, tarfile

repo = pathlib.Path('/private/tmp/rightclick-patch-release-parity-20261007')
archive = repo/'dist/rightclick-0.2.3-source.tar.gz'
previous = pathlib.Path('/private/tmp/rightclick-final-batched-source-first-20261007.tar.gz')
sha = lambda b: hashlib.sha256(b).hexdigest()
expected_sha = 'f98408da81bd45ebcd526fcf9eb4995d4bd2bc471b1c58254792970e1befd054'
assert sha(archive.read_bytes()) == expected_sha
version = '0.2.3'
assert f'current = "{version}"' in (repo/'Sources/RightClickCore/ProductSurface.swift').read_text()
inputs = ['Package.swift','Package.resolved','LICENSE','Sources','Tests','Vendor','fixtures','packaging/ThirdPartyLicenses','packaging/substrate-kinds.json','scripts/build-cli.sh']
paths = set()
for name in inputs:
    p=repo/name
    paths.add(p)
    if p.is_dir(): paths.update(p.rglob('*'))
script_modes={}
for entry in subprocess.check_output(['git','ls-files','--stage','-z','--','scripts'],cwd=repo).decode().split('\0'):
    if not entry: continue
    metadata,name=entry.split('\t',1)
    mode,_,stage=metadata.split()
    assert stage=='0'
    script_modes[name]=int(mode,8)
    paths.add(repo/name)
expected={p.relative_to(repo).as_posix():p for p in paths}
def inventory(tarpath, verify=False):
    result={}
    with tarfile.open(tarpath) as t:
        names=t.getnames()
        assert len(names)==len(set(names))
        for member in t:
            prefix=f'rightclick-{version}/'
            assert member.name.startswith(prefix)
            name=member.name[len(prefix):]
            assert not any(x in pathlib.PurePosixPath(name).parts for x in ['..','.git','.build','__pycache__'])
            assert member.isfile() or member.isdir()
            assert member.uid==member.gid==0 and member.uname==member.gname=='root' and member.mtime==1767225600
            data=t.extractfile(member).read() if member.isfile() else b''
            result[name]={'sha256':sha(data),'mode':member.mode,'bytes':len(data),'directory':member.isdir()}
            if verify:
                p=expected[name]
                assert not p.is_symlink()
                assert p.is_dir()==member.isdir()
                expected_mode=0o755 if p.is_dir() or name=='scripts/build-cli.sh' or script_modes.get(name,0)&0o111 else 0o644
                assert member.mode==expected_mode,(name,member.mode,expected_mode)
                if member.isfile(): assert data==p.read_bytes(),name
    if verify: assert set(result)==set(expected)
    return result
current=inventory(archive,True); old=inventory(previous)
assert set(current)==set(old)
changed=[name for name in current if current[name]!=old[name]]
assert sorted(changed)==['Sources/RightClickARDProbe/main.swift','scripts/acceptance-linux-dbus.py','scripts/dbus-private-fixture.py'],changed
manifest=json.loads((repo/'packaging/substrate-kinds.json').read_text())
formula1=repo/'packaging/homebrew/rightclick.rb';formula2=repo/'packaging/tap/Formula/rightclick.rb'
assert formula1.read_bytes()==formula2.read_bytes()
formula=formula1.read_text()
assert f'/v{version}/rightclick-{version}-source.tar.gz' in formula and f'sha256 "{expected_sha}"' in formula
assert 'bottle do' not in formula
assert 'b2cae3aa9df45b4c2fe9b1d700ebacce39f9feb6a6b46b86e6499f9a51bf72ff' in formula
report={'status':'PASS_EXACT_RECONCILED_SOURCE_PACKAGE_CLOSURE','sourceHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'sourcesTree':subprocess.check_output(['git','rev-parse','HEAD:Sources'],cwd=repo,text=True).strip(),'runtimeVersion':version,'archiveSHA256':expected_sha,'memberCount':len(current),'trackedScripts':len(script_modes),'changedPackageMembersFromFrozenD2':changed,'memberBytesModesAndClosedInventory':'PASS','formulaEquality':'PASS','resourcePinUnchanged':'PASS','legacyBottleBlockAbsent':True,'substrateManifest':manifest,'scope':'Local deterministic package/input equality only; fresh reconciled source build/platform/runtime/provider/public release/install acceptance pending.'}
out=pathlib.Path('/private/tmp/rightclick-reconciled-package-audit-20261008.json')
out.write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if k!='substrateManifest'}))
