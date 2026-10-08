"""Fixture preparation/argv controls only; native 13/product gates are separate."""
import ast
import pathlib
import os
import stat
import tempfile
import unittest
import uuid
from unittest import mock
import xml.etree.ElementTree as ET

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "acceptance-linux-dbus.py"


def preparation(temporary, output):
    # Execute the actual fixture preparation statements only, stopping before
    # any subprocess. No import of the top-level acceptance/proof client occurs.
    tree = ast.parse(SCRIPT.read_text())
    main = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
    body = next(node for node in main.body if isinstance(node, ast.With)).body
    statements = []
    for node in body:
        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == "daemon" for target in node.targets):
            break
        statements.append(node)
    else:
        raise AssertionError("Fixture preparation did not stop before the first subprocess")
    namespace = {"temporary": temporary, "out": output, "pathlib": pathlib, "os": os, "uuid": uuid,
        "NAME": "org.rightclick.Pressure", "INTERFACE": "org.rightclick.Pressure"}
    with mock.patch.object(os, "chown") as chown:
        exec(compile(ast.Module(body=statements, type_ignores=[]), str(SCRIPT), "exec"), namespace)
        return namespace, chown.call_args_list


class PrincipalControls(unittest.TestCase):
    def test_actual_preparation_root_is_writer_group_readable_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "private"; root.mkdir()
            output = pathlib.Path(tmp) / "public"; output.mkdir()
            namespace, ownership = preparation(str(root), output)
            self.assertEqual(ownership[0], mock.call(root, 0, 1100))
            mode = stat.S_IMODE(root.stat().st_mode)
            self.assertEqual(mode, 0o751)
            self.assertTrue(mode & stat.S_IRGRP)
            self.assertTrue(mode & stat.S_IXGRP)
            self.assertFalse(mode & (stat.S_IWGRP | stat.S_IROTH | stat.S_IWOTH))
            self.assertTrue(mode & stat.S_IXOTH)
            self.assertEqual(namespace["root"], root)

    def test_actual_preparation_preserves_private_writer_and_shared_observer_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "private"; root.mkdir()
            output = pathlib.Path(tmp) / "public"; output.mkdir()
            _, ownership = preparation(str(root), output)
            expected = {"state": (1102, 1101, 0o750), "records": (1102, 1101, 0o750),
                "observer-state": (1101, 1101, 0o750), "writer-state": (1100, 1100, 0o700)}
            for name, (owner, group, mode) in expected.items():
                self.assertIn(mock.call(root / name, owner, group), ownership)
                self.assertEqual(stat.S_IMODE((root / name).stat().st_mode), mode)
            for path, owner in ((root / "observer.token", 1101), (root / "writer-state/observer.token", 1100)):
                self.assertIn(mock.call(path, owner, owner), ownership)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_actual_preparation_preserves_exact_bus_method_separation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "private"; root.mkdir()
            output = pathlib.Path(tmp) / "public"; output.mkdir()
            namespace, _ = preparation(str(root), output)
            policy = ET.parse(root / "bus.conf").getroot()
            policies = {node.get("user"): node for node in policy.findall("policy") if node.get("user")}
            writer = policies["rcwriter"].findall("allow")
            self.assertEqual({entry.get("send_member") for entry in writer}, {"Store", "EchoTags", "Acknowledge"})
            self.assertTrue(all(entry.get("send_destination") == "org.rightclick.Pressure" for entry in writer))
            observer = policies["rcobserver"].findall("allow")
            self.assertEqual(len(observer), 1)
            self.assertEqual(observer[0].get("send_member"), "GetProof")
            service = policies["rcservice"].findall("allow")
            self.assertEqual([entry.attrib for entry in service], [{"own": "org.rightclick.Pressure"}])
            self.assertNotIn(namespace["token"], (output / "private-bus-policy.xml").read_text())

    def test_actual_writer_observer_service_argv_has_no_inherited_root_groups(self):
        tree = ast.parse(SCRIPT.read_text())
        identities = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "Popen":
                kwargs = {item.arg: item.value for item in node.keywords}
                if "user" not in kwargs:
                    continue
                identities.append((ast.literal_eval(kwargs["user"]), ast.literal_eval(kwargs["group"]), ast.literal_eval(kwargs["extra_groups"])))
        self.assertEqual(sorted(identities), [(1100, 1100, []), (1101, 1101, []), (1102, 1101, [])])
        # Service GID1101 is intentional: exactly the observer-readable record
        # group. Changing it independently would destroy independent readback.

    def test_direct_bus_control_uid_always_uses_same_gid_and_no_extra_groups(self):
        tree = ast.parse(SCRIPT.read_text())
        call = next(node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "run" and any(keyword.arg == "user" for keyword in node.keywords))
        kwargs = {item.arg: item.value for item in call.keywords}
        self.assertEqual(ast.dump(kwargs["user"]), ast.dump(kwargs["group"]))
        self.assertIsInstance(kwargs["user"], ast.Name); self.assertEqual(kwargs["user"].id, "uid")
        self.assertEqual(ast.literal_eval(kwargs["extra_groups"]), [])

    def test_provisioned_host_file_still_requires_private_writer_reference(self):
        tree = ast.parse(SCRIPT.read_text())
        save = next(node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and node.name == "save")
        with tempfile.TemporaryDirectory() as tmp:
            host = pathlib.Path(tmp) / "host.json"
            namespace = {"host": host, "settings": {"version": 1}, "os": os, "json": __import__("json")}
            with mock.patch.object(os, "chown") as chown:
                exec(compile(ast.Module(body=save.body, type_ignores=[]), str(SCRIPT), "exec"), namespace)
            chown.assert_called_once_with(host, 1100, 1100)
            self.assertEqual(stat.S_IMODE(host.stat().st_mode), 0o600)


if __name__ == "__main__": unittest.main()
