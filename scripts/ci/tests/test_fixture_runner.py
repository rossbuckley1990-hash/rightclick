"""The native shell runner preserves arguments and the actual process failure."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class FixtureRunnerTests(unittest.TestCase):
    def check_runner(self, scratch):
        with tempfile.TemporaryDirectory(prefix="rightclick-runner-control-") as temporary:
            root = Path(temporary)
            executable = root / "swift"
            executable.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                                  "with open(os.environ['CONTROL_ARGUMENTS'], 'w') as stream:\n"
                                  "    json.dump(sys.argv[1:], stream)\n"
                                  "sys.exit(23)\n")
            executable.chmod(0o700)
            arguments = root / "arguments.json"
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               CONTROL_ARGUMENTS=str(arguments), PYTHONDONTWRITEBYTECODE="1")
            environment.pop("RIGHTCLICK_TEST_SCRATCH_PATH", None)
            if scratch is not None:
                environment["RIGHTCLICK_TEST_SCRATCH_PATH"] = scratch
            completed = subprocess.run(["bash", str(ROOT / "scripts/ci/run-fixture-tests.sh"),
                "NativeServiceUnicodeLiveAcceptanceTests", str(root / "tests.log"),
                str(root / "outcomes.json"), "--require-class", "NativeServiceUnicodeLiveAcceptanceTests"],
                cwd=ROOT, env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 23, completed.stdout + completed.stderr)
            self.assertEqual((root / "tests.log.exit").read_text(), "23\n")
            expected = ["test", "--force-resolved-versions", "--jobs", "4"]
            if scratch is not None:
                expected += ["--scratch-path", scratch]
            expected += ["--filter", "NativeServiceUnicodeLiveAcceptanceTests"]
            self.assertEqual(json.loads(arguments.read_text()), expected)

    def test_default_scratch_runs_on_native_shell_and_preserves_failure(self):
        self.check_runner(None)

    def test_scratch_path_with_spaces_is_one_argument(self):
        self.check_runner("/tmp/private runner control")
