"""Post-fix safeguard checks, added after the separate frozen RED controls.

Only disposable SYNTHETIC files are used. This is not acceptance evidence and
does not add to the historical pre-fix RED counts.
"""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from Tests.test_universal_scorecard_adversarial import GATE


class UniversalScorecardProtectedReadTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="rightclick-synthetic-protected-read-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "repository"
        self.root.mkdir()
        self.artifact = self.root / "synthetic.txt"
        data = b"SYNTHETIC protected-read control; no real acceptance\n"
        self.artifact.write_bytes(data)
        self.reference = {"path": self.artifact.name,
                          "sha256": hashlib.sha256(data).hexdigest()}

    def test_replacement_during_actual_open_is_rejected(self):
        outside = Path(self.directory.name) / "outside-synthetic.txt"
        outside.write_bytes(self.artifact.read_bytes())
        original_open = os.open
        supported = set(os.supports_dir_fd)
        swapped = []

        def replace_then_open(path, flags, mode=0o777, *, dir_fd=None):
            if path == self.artifact.name and dir_fd is not None and not swapped:
                self.artifact.unlink()
                self.artifact.symlink_to(outside)
                swapped.append(True)
            return original_open(path, flags, mode, dir_fd=dir_fd)

        with patch.object(os, "open", new=replace_then_open), \
                patch.object(os, "supports_dir_fd", supported | {replace_then_open}):
            with self.assertRaisesRegex(GATE.InvalidScorecard, "cannot safely open evidence"):
                GATE.evidence_reference(self.reference, self.root)
        self.assertEqual(swapped, [True], "Replacement must occur at the actual file open")

    def test_hard_link_alias_is_rejected_for_both_paths(self):
        alias = self.root / "synthetic-alias.txt"
        os.link(self.artifact, alias)
        for path in [self.artifact, alias]:
            with self.subTest(path=path.name):
                reference = {**self.reference, "path": path.name}
                with self.assertRaisesRegex(GATE.InvalidScorecard, "hard-link aliases"):
                    GATE.evidence_reference(reference, self.root)


if __name__ == "__main__":
    unittest.main()
