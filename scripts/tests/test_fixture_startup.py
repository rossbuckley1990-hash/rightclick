import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest
import uuid

spec = importlib.util.spec_from_file_location('fixture_startup', pathlib.Path(__file__).resolve().parents[1] / 'fixture_startup.py')
startup = importlib.util.module_from_spec(spec); spec.loader.exec_module(startup)

class FixtureStartupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='rightclick-fixture-test-')
        self.root = pathlib.Path(self.temporary.name)
        self.diagnostics = self.root / 'public.json'
        self.private_directories = []
    def tearDown(self):
        self.temporary.cleanup()
        import shutil
        for directory in self.private_directories:
            shutil.rmtree(directory)
    def group(self):
        group = startup.FixtureProcesses(self.diagnostics)
        if group.private_directory: self.private_directories.append(group.private_directory)
        return group
    def script(self, code):
        script = self.root / (uuid.uuid4().hex + '.py'); script.write_text(code); return script
    def metadata(self): return json.loads(self.diagnostics.read_bytes())['children'][0]

    def testActualEarlyExitIsClassifiedAndSiblingIsCleaned(self):
        with self.assertRaises(startup.FixtureStartupError) as captured:
            with self.group() as group:
                exited = group.launch('failed', self.script('import sys; sys.exit(7)'), [], self.root / 'absent')
                alive = group.launch('sibling', self.script('import time; time.sleep(60)'), [], self.root / 'sibling-port')
                before = time.monotonic(); group.wait_for_port('failed', timeout=2)
        self.assertLess(time.monotonic() - before, 2)
        self.assertEqual(str(captured.exception), 'fixture failed: child_exited')
        self.assertEqual(exited.returncode, 7); self.assertIsNotNone(alive.poll())
        self.assertEqual(self.metadata()['exitAtReadiness'], 7)

    def testPrivateErrorIsRetainedWithoutAppearingInPublicMetadata(self):
        secret = 'Bearer synthetic-' + uuid.uuid4().hex
        with self.assertRaises(startup.FixtureStartupError) as captured:
            with self.group() as group:
                group.launch('failed', self.script('import sys\nsys.stderr.write(' + repr(secret) + ')\nsys.exit(9)'), [], self.root / 'absent')
                group.wait_for_port('failed', timeout=2)
        self.assertFalse(secret in self.diagnostics.read_text() + str(captured.exception), 'private body reached public metadata')
        row = self.metadata(); self.assertEqual(row['stderrBytes'], len(secret))
        if group.private_directory:
            self.assertEqual((group.private_directory.stat().st_mode & 0o777), 0o700)
            private = group.private_directory / 'failed.stderr.private'
            self.assertEqual(private.stat().st_mode & 0o777, 0o600)
            self.assertTrue(private.read_text() == secret, 'actual private bytes were not retained')

    def testAliveTimeoutIsBoundedAndTerminatesChild(self):
        with self.assertRaises(startup.FixtureStartupError) as captured:
            with self.group() as group:
                child = group.launch('slow', self.script('import time; time.sleep(60)'), [], self.root / 'absent')
                start = time.monotonic(); group.wait_for_port('slow', timeout=.2)
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual(str(captured.exception), 'fixture slow: readiness_timeout')
        self.assertIsNotNone(child.poll())
        self.assertEqual(self.metadata()['readiness'], 'readiness_timeout')

    def testActualMarkerReadinessAndCleanup(self):
        marker = self.root / 'port'
        code = 'import pathlib,time\npathlib.Path(' + repr(str(marker)) + ').write_text("4242")\ntime.sleep(60)'
        with self.group() as group:
            child = group.launch('ready', self.script(code), [], marker)
            self.assertEqual(group.wait_for_port('ready', timeout=2), '4242')
            self.assertIsNone(child.poll())
        self.assertIsNotNone(child.poll()); self.assertEqual(self.metadata()['readiness'], 'ready')
        self.assertLess(self.metadata()['readinessElapsedMilliseconds'], 2000)

    def testInvalidPortAndSymlinkDoNotBecomeReady(self):
        for value in ('0', '65536', '4242evil', '7' * 100):
            with self.subTest(value=value):
                marker = self.root / (uuid.uuid4().hex + '.port'); marker.write_text(value)
                with self.assertRaises(startup.FixtureStartupError):
                    with self.group() as group:
                        group.launch('invalid', self.script('import time; time.sleep(60)'), [], marker)
                        group.wait_for_port('invalid', timeout=2)
                self.assertEqual(self.metadata()['readiness'], 'invalid_readiness')
        if hasattr(os, 'O_NOFOLLOW'):
            target = self.root / 'target'; target.write_text('4242')
            link = self.root / 'link'; link.symlink_to(target)
            with self.assertRaises(startup.FixtureStartupError):
                with self.group() as group:
                    group.launch('linked', self.script('import time; time.sleep(60)'), [], link)
                    group.wait_for_port('linked', timeout=2)
            self.assertEqual(self.metadata()['readiness'], 'readiness_read_failed')

    def testStderrFloodIsDrainedAndBounded(self):
        with self.assertRaises(startup.FixtureStartupError):
            with self.group() as group:
                group.launch('flood', self.script('import sys\nsys.stderr.buffer.write(b"x" * 1048576)\nsys.exit(8)'), [], self.root / 'absent')
                group.wait_for_port('flood', timeout=3)
        row = self.metadata()
        self.assertEqual(row['exitAtReadiness'], 8); self.assertEqual(row['stderrBytes'], 1048576)
        self.assertEqual(row['stderrRetainedBytes'], startup.MAX_STDERR); self.assertTrue(row['stderrTruncated'])

    def testTimeoutCannotWidenAndExitedMarkerDoesNotCount(self):
        marker = self.root / 'port'; marker.write_text('4242')
        with self.group() as group:
            child = group.launch('exited', self.script('import sys; sys.exit(0)'), [], marker)
            child.wait(timeout=2)
            with self.assertRaises(ValueError): group.wait_for_port('exited', timeout=11)
            with self.assertRaises(startup.FixtureStartupError): group.wait_for_port('exited', timeout=2)
        self.assertEqual(self.metadata()['exitAtReadiness'], 0)

    def testSlowStackStaysPrivateAndBounded(self):
        booted = self.root / 'booted'
        code = 'import pathlib,time\npathlib.Path(' + repr(str(booted)) + ').write_text("booted")\ntime.sleep(60)'
        with self.assertRaises(startup.FixtureStartupError):
            with self.group() as group:
                group.launch('blocked', self.script(code), [], self.root / 'absent')
                deadline = time.monotonic() + 3
                while not booted.exists() and time.monotonic() < deadline: time.sleep(.01)
                self.assertTrue(booted.exists(), 'actual child must reach the blocked control')
                group.wait_for_port('blocked', timeout=5.4)
        row = self.metadata(); self.assertGreater(row['stderrBytes'], 0)
        self.assertFalse('File "' in self.diagnostics.read_text(), 'private stack reached public metadata')
        if group.private_directory:
            text = (group.private_directory / 'blocked.stderr.private').read_text()
            self.assertTrue('Timeout (0:00:05)!' in text, 'actual delayed child stack missing')

if __name__ == '__main__': unittest.main()
