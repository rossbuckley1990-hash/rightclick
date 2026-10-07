#!/usr/bin/env python3
"""Execute the packaged binary in a Linux host that has no Swift toolchain."""
import json, pathlib, shutil, subprocess, sys
from portable_bundle import verify_bundle
from portable_acceptance import measure
from portable_common import write_json, host
artifacts=pathlib.Path(sys.argv[1]).resolve(); output=pathlib.Path(sys.argv[2]).resolve()
assert sys.platform.startswith('linux') and shutil.which('swift') is None
assert not pathlib.Path('/usr/local/swift').exists()
archives=list(artifacts.glob('*-candidate.zip')); assert len(archives)==1
archive=archives[0]; checksum=archive.with_suffix('.sha256').read_text().split()[0]
manifest=verify_bundle(archive,checksum,output/'extracted')
assert manifest['host']==host()
binary=output/'extracted'/manifest['executable']
linked=subprocess.run(['ldd',str(binary)],capture_output=True,text=True,check=True,timeout=30).stdout
assert 'not found' not in linked and '/usr/local/swift' not in linked
output.mkdir(parents=True,exist_ok=True); (output/'dynamic-libraries.log').write_text(linked)
report=measure(binary,output/'clean-machine.json',manifest['sourceSHA'],count=1,http=True,cleaned=True)
assert report['result']=='PASS'
write_json(output/'clean-environment.json',{'result':'PASS','sourceSHA':manifest['sourceSHA'],
    'archiveSHA256':checksum,'host':host(),'swiftToolchainPresent':False,
    'boundary':'Ubuntu 24.04 with OS runtime libraries and Python test driver; no Swift compiler or installed Swift runtime.'})
print(json.dumps(report['summary'],indent=2))
