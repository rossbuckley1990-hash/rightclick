import importlib.util
from pathlib import Path
import os
import shutil
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/ci/check-windows-sdk-provenance.py"
spec = importlib.util.spec_from_file_location("sdk_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
SOURCE = Path(os.environ.get("RIGHTCLICK_SDK_TEST_ROOT", str(SCRIPT.parents[2] / "Vendor/mcp-swift-sdk")))


class WindowsSDKProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.snapshot = Path(self.directory.name) / "snapshot"
        shutil.copytree(SOURCE, self.snapshot)

    def tearDown(self):
        self.directory.cleanup()

    def testExactClosurePassesWithoutClaimingWindowsRuntime(self):
        result = gate.check(self.snapshot)
        self.assertEqual((result["files"], result["mcpSwiftSources"], result["status"]), (50, 47, "passed"))
        self.assertEqual(result["nativeWindowsBuild"], "not evaluated by this source provenance gate")

    def testChangedSourceRejected(self):
        with (self.snapshot / "Sources/MCP/Base/Error.swift").open("a") as stream:
            stream.write("\n// tampered\n")
        with self.assertRaisesRegex(gate.ProvenanceError, "source hash changed"):
            gate.check(self.snapshot)

    def testMissingSourceRejected(self):
        (self.snapshot / "Sources/MCP/Base/Error.swift").unlink()
        with self.assertRaisesRegex(gate.ProvenanceError, "inventory changed"):
            gate.check(self.snapshot)

    def testUnexpectedSourceRejected(self):
        (self.snapshot / "Sources/MCP/Injected.swift").write_text("// injection\n")
        with self.assertRaisesRegex(gate.ProvenanceError, "inventory changed"):
            gate.check(self.snapshot)

    def testNestedManifestNameIsNotExempted(self):
        (self.snapshot / "Sources/MCP/snapshot-provenance.json").write_text('{}')
        with self.assertRaisesRegex(gate.ProvenanceError, "inventory changed"):
            gate.check(self.snapshot)

    def testRewrittenManifestCannotBlessTampering(self):
        path = self.snapshot / "snapshot-provenance.json"
        path.write_text(path.read_text().replace('"Windows only"', '"All platforms"'))
        with self.assertRaisesRegex(gate.ProvenanceError, "provenance pin changed"):
            gate.check(self.snapshot)

    def testSymlinkedSourceRejected(self):
        path = self.snapshot / "Sources/MCP/Base/Error.swift"
        content = path.read_text()
        path.unlink()
        target = Path(self.directory.name) / "outside.swift"
        target.write_text(content)
        path.symlink_to(target)
        with self.assertRaisesRegex(gate.ProvenanceError, "Symlink in SDK"):
            gate.check(self.snapshot)

    def testSymlinkedSnapshotRejected(self):
        linked = Path(self.directory.name) / "linked"
        linked.symlink_to(self.snapshot, target_is_directory=True)
        with self.assertRaisesRegex(gate.ProvenanceError, "symlinked SDK snapshot"):
            gate.check(linked)


if __name__ == "__main__":
    unittest.main()
