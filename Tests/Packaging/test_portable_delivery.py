"""Packaging rejection tests. These do NOT replace real binary acceptance."""
import hashlib
import importlib.util
import json
import pathlib
import stat
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('delivery', ROOT/'scripts/portable-delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)

class PackageIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def archive(self, extra=None, manifest_patch=None):
        data = b'packaging-test-fixture-not-an-executable'
        files = {'bin/rightclick': data, 'LICENSE': b'test fixture'}
        if extra: files.update(extra)
        hashes = {n:hashlib.sha256(v).hexdigest() for n,v in files.items()}
        manifest = {'schema':1, 'sourceSHA':'a'*40, 'files':hashes,
                    'executable':'bin/rightclick', 'binarySHA256':hashes['bin/rightclick']}
        if manifest_patch: manifest.update(manifest_patch)
        files['manifest.json'] = json.dumps(manifest).encode()
        path = self.root/'candidate.zip'
        with zipfile.ZipFile(path,'w') as z:
            for n,b in files.items():
                i=zipfile.ZipInfo(n);i.external_attr=(stat.S_IFREG|0o644)<<16
                z.writestr(i,b)
        return path
    def verify(self, path):
        return delivery.verify_bundle(path, delivery.sha256(path), self.root/'extracted')
    def test_valid_integrity_extracts_without_executing(self):
        manifest=self.verify(self.archive())
        self.assertEqual(manifest['sourceSHA'],'a'*40)
        self.assertEqual((self.root/'extracted/bin/rightclick').read_bytes(),b'packaging-test-fixture-not-an-executable')
    def test_wrong_outer_hash_rejected_before_extraction(self):
        path=self.archive()
        with self.assertRaises(ValueError): delivery.verify_bundle(path,'0'*64,self.root/'extracted')
        self.assertFalse((self.root/'extracted').exists())
    def test_member_tamper_rejected_even_with_matching_outer_hash(self):
        path=self.archive(manifest_patch={'binarySHA256':'0'*64})
        with self.assertRaises(ValueError): self.verify(path)
        self.assertFalse((self.root/'extracted').exists())
    def test_manifest_omission_rejected(self):
        with self.assertRaises(ValueError): self.verify(self.archive(manifest_patch={'files':{}}))
    def test_manifest_inner_hash_rejected(self):
        with self.assertRaises(ValueError): self.verify(self.archive(manifest_patch={'files':{'bin/rightclick':'0'*64,'LICENSE':'0'*64}}))
    def test_source_identity_is_required(self):
        with self.assertRaises(ValueError): self.verify(self.archive(manifest_patch={'sourceSHA':'main'}))
    def test_path_traversal_rejected(self):
        for name in ['../outside','/absolute','bin/../outside','bin//bad','a\\b','C:/bad','CON','a/NUL.txt','trailing.','a\x01b']:
            with self.subTest(name=name),self.assertRaises(ValueError): self.verify(self.archive(extra={name:b'x'}))
        self.assertFalse((self.root/'outside').exists())
    def test_conflicting_file_directory_rejected(self):
        with self.assertRaises(ValueError): self.verify(self.archive(extra={'bin':b'x'}))
    def test_case_insensitive_parent_collision_rejected(self):
        with self.assertRaises(ValueError): self.verify(self.archive(extra={'BIN':b'x'}))
    def test_case_collision_rejected(self):
        with self.assertRaises(ValueError): self.verify(self.archive(extra={'BIN/rightclick':b'x'}))
    def test_existing_destination_is_never_overwritten(self):
        destination=self.root/'extracted';destination.mkdir();(destination/'keep').write_text('keep')
        with self.assertRaises(ValueError): self.verify(self.archive())
        self.assertEqual((destination/'keep').read_text(),'keep')
    def test_symlink_member_rejected(self):
        path=self.archive()
        with zipfile.ZipFile(path,'a') as z:
            i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=(stat.S_IFLNK|0o777)<<16
            z.writestr(i,'/outside')
        with self.assertRaises(ValueError): self.verify(path)
    def test_nonpassing_binary_report_cannot_bundle(self):
        binary=self.root/'not-a-runtime';binary.write_bytes(b'fixture')
        report=self.root/'report.json';report.write_text(json.dumps({'result':'FAIL'}))
        # Invalid source identity must fail before invoking git, swift or the fixture.
        with self.assertRaises(ValueError): delivery.bundle(binary,report,self.root/'output','not-a-commit')
    def test_atomic_report_round_trip(self):
        p=self.root/'report/value.json';delivery.write_json(p,{'result':'FAIL'})
        self.assertEqual(json.loads(p.read_text()),{'result':'FAIL'})
        delivery.write_json(p,{'result':'PASS'})
        self.assertEqual(json.loads(p.read_text()),{'result':'PASS'})
    def test_invalid_sample_count_fails_before_execution(self):
        p=self.root/'not-a-runtime';p.write_text('fixture')
        with self.assertRaises(ValueError): delivery.measure(p,self.root/'report','a'*40,count=0)

if __name__=='__main__': unittest.main()
