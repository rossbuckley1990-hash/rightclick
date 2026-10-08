"""Archive boundary controls using disposable real Git indexes; no Swift build."""
import importlib.util
import io
from pathlib import Path
import os
import subprocess
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/archive_inputs.py"
spec = importlib.util.spec_from_file_location("archive_inputs", SCRIPT)
archive_inputs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive_inputs)


class TrackedArchiveInputsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rightclick-archive-boundary-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "core.filemode", "true")
        self.required = ["Package.swift", "Sources", "Tests", "docs/substrate-contract.json",
                         "docs/reconciliation-baselines", "examples/universal-descriptors",
                         "examples/rcir-authority-benchmark"]
        self.files = ["Package.swift", "Sources/Core/a.swift", "Tests/Core/a.swift",
                      "scripts/build-cli.sh", "scripts/ci/check.py", "docs/substrate-contract.json",
                      "docs/reconciliation-baselines/input.json",
                      "examples/universal-descriptors/component.wat",
                      "examples/rcir-authority-benchmark/run.py"]
        for value in self.files:
            self.write(value, ("tracked " + value + "\n").encode())
        self.write(".gitignore", b"__pycache__/\n*.private\n")
        self.git("add", "--", *self.files, ".gitignore")

    def git(self, *arguments, input=None):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], input=input)

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def collect(self, required=None):
        return archive_inputs.tracked_archive_inputs(self.root, required or self.required)

    def assert_rejected(self, text, required=None):
        with self.assertRaisesRegex(archive_inputs.ArchiveInputError, text):
            self.collect(required)

    def test_all_required_source_closures_are_selected(self):
        entries = self.collect()
        self.assertEqual({str(entry.relative) for entry in entries if not entry.is_directory}, set(self.files))
        self.assertIn("docs/reconciliation-baselines", {str(entry.relative) for entry in entries if entry.is_directory})
        self.assertIn("examples/universal-descriptors", {str(entry.relative) for entry in entries if entry.is_directory})

    def test_ignored_bytecode_and_untracked_private_files_never_enter(self):
        extras = ["Tests/ci/__pycache__/secret.pyc", "Sources/local.private", "Tests/debug-diagnostic.txt",
                  "scripts/ci/private-note.txt", "docs/reconciliation-baselines/local-token.private",
                  "examples/universal-descriptors/private-key.raw"]
        for value in extras:
            self.write(value, b"private canary excluded from source archive")
        entries = self.collect()
        self.assertEqual({str(entry.relative) for entry in entries if not entry.is_directory}, set(self.files))
        self.assertFalse(any("__pycache__" in str(entry.relative) for entry in entries))

    def test_dirty_tracked_working_bytes_are_preserved(self):
        path = self.write("Sources/Core/a.swift", b"reviewed dirty working-tree source\n")
        entries = self.collect()
        selected = next(entry for entry in entries if str(entry.relative) == "Sources/Core/a.swift")
        self.assertEqual((self.root / selected.relative).read_bytes(), path.read_bytes())
        self.assertNotEqual(self.git("show", ":Sources/Core/a.swift"), path.read_bytes())

    def test_executable_mode_comes_from_git_index(self):
        self.git("update-index", "--chmod=+x", "scripts/build-cli.sh")
        (self.root / "scripts/build-cli.sh").chmod(0o644)
        entries = {str(entry.relative): entry for entry in self.collect()}
        self.assertEqual(entries["scripts/build-cli.sh"].mode, 0o755)
        self.assertEqual(entries["Sources/Core/a.swift"].mode, 0o644)
        self.assertEqual(entries["Sources"].mode, 0o755)

    def test_missing_tracked_file_fails(self):
        (self.root / "Sources/Core/a.swift").unlink()
        self.assert_rejected("Missing tracked archive input")

    def test_required_untracked_file_fails(self):
        self.write("required.json", b"not indexed")
        self.assert_rejected("no tracked files", self.required + ["required.json"])

    def test_required_directory_with_only_untracked_files_fails(self):
        self.write("empty-required/local.txt", b"not indexed")
        self.assert_rejected("no tracked files", self.required + ["empty-required"])

    @unittest.skipUnless(hasattr(os, "symlink"), "Host has no symlink API")
    def test_working_tree_symlink_fails(self):
        path = self.root / "Sources/Core/a.swift"
        path.unlink()
        try:
            path.symlink_to(self.root / "Package.swift")
        except OSError as error:
            self.skipTest("Native symlink creation unavailable: " + str(error))
        self.assert_rejected("Symlinked archive input")

    @unittest.skipUnless(hasattr(os, "symlink"), "Host has no symlink API")
    def test_tracked_symlink_mode_fails_even_after_working_replacement(self):
        path = self.root / "Sources/Core/link.swift"
        try:
            path.symlink_to("a.swift")
        except OSError as error:
            self.skipTest("Native symlink creation unavailable: " + str(error))
        self.git("add", "--", "Sources/Core/link.swift")
        path.unlink()
        path.write_bytes(b"regular replacement does not erase tracked symlink mode")
        self.assert_rejected("Unsupported tracked archive file mode")

    @unittest.skipUnless(hasattr(os, "symlink"), "Host has no symlink API")
    def test_symlinked_parent_fails(self):
        parent = self.root / "Sources/Core"
        parent.rename(self.root / "outside")
        try:
            parent.symlink_to(self.root / "outside", target_is_directory=True)
        except OSError as error:
            self.skipTest("Native symlink creation unavailable: " + str(error))
        self.assert_rejected("Symlinked archive input or parent")

    def test_unmerged_selected_file_fails(self):
        sha = self.git("rev-parse", ":Sources/Core/a.swift").decode().strip()
        self.git("update-index", "--index-info", input=("0 " + "0"*40 + "\tSources/Core/a.swift\n"
                 + "100644 " + sha + " 1\tSources/Core/a.swift\n"
                 + "100644 " + sha + " 2\tSources/Core/a.swift\n").encode())
        self.assert_rejected("Unmerged archive input")

    def test_tracked_gitlink_is_not_silently_replaced_by_working_bytes(self):
        sha = self.git("rev-parse", ":Sources/Core/a.swift").decode().strip()
        self.git("update-index", "--cacheinfo", "160000", sha, "Sources/Core/a.swift")
        self.assert_rejected("Unsupported tracked archive file mode")

    def test_parent_escape_and_git_metadata_paths_fail(self):
        for value in ["../outside", "/absolute", "Sources/../Tests", ".git/config", "Sources\\Core"]:
            with self.subTest(value=value):
                self.assert_rejected("canonical relative paths", self.required + [value])

    def test_output_is_sorted_and_nonduplicated_for_overlapping_requests(self):
        entries = self.collect(self.required + ["scripts/build-cli.sh", "scripts"])
        self.assertEqual([entry.relative for entry in entries], sorted(set(entry.relative for entry in entries)))
        self.assertEqual(sum(str(entry.relative) == "scripts/build-cli.sh" for entry in entries), 1)

    def test_archive_uses_only_selected_names_and_working_bytes(self):
        self.write("Tests/ci/__pycache__/local.pyc", b"must not enter tar")
        self.write("Sources/Core/a.swift", b"current working bytes")
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w") as archive:
            for entry in self.collect():
                path = self.root / entry.relative
                info = archive.gettarinfo(str(path), arcname=str(entry.relative))
                info.mode = entry.mode
                if entry.is_directory:
                    archive.addfile(info)
                else:
                    with path.open("rb") as stream:
                        archive.addfile(info, stream)
        output.seek(0)
        with tarfile.open(fileobj=output) as archive:
            self.assertNotIn("Tests/ci/__pycache__/local.pyc", archive.getnames())
            self.assertEqual(archive.extractfile("Sources/Core/a.swift").read(), b"current working bytes")


if __name__ == "__main__":
    unittest.main()
