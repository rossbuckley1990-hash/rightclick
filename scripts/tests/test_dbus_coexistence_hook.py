"""Isolated adapter controls; no RIGHTCLICK, D-Bus, Swift or execution proof."""
import importlib.util
import json
import os
import pathlib
import signal
import stat
import sys
import subprocess
import tempfile
import types
import unittest
from unittest import mock

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("dbus_hook", SCRIPTS / "ci/dbus-coexistence-hook.py")
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


def passing_report():
    supplied = (*hook.CONTROLLED, "dbus")
    rows = {family: {"implemented": None, "compiles": None, "discovered": None,
        "executed": None, "executionNodeVerified": None, "verified": None,
        "liveWithdrawalTested": None, "platformsTested": [], "status": "UNPROVEN"}
        for family in hook.FAMILIES}
    for family in supplied:
        rows[family].update(discovered=True, executed=True, executionNodeVerified=True,
            verified=True, liveWithdrawalTested=True if family in hook.CONTROLLED else None,
            platformsTested=["linux"], status="VERIFIED",
            independentObservation={"kind": "returned-text" if family == "dbus" else "http-text", "exactExpectedMatched": True},
            receipt={"independentSignatureVerified": True, "selectedCapabilityMatched": True, "payloadSHA256": "public-hash"})
    return {"status": "PARTIAL_BOUNDARY_PASS", "errors": [], "singleClient": True,
        "singleRuntimeProcess": True, "clientProcessCount": 1, "canonicalOperations": sorted(hook.TOOLS),
        "runtimePlatform": "linux", "binarySHA256": "binary", "oneGraphSuppliedFamilies": sorted(supplied), "rows": rows}


class AdapterControls(unittest.TestCase):
    def test_manifest_has_only_live_bus_environment_no_existing_token_or_host(self):
        actual = hook.manifest("unix:path=/tmp/private-bus/bus")
        self.assertEqual(actual["environment"], {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/private-bus/bus"})
        self.assertEqual(actual["runtimeUID"], 1100)
        self.assertEqual(set(actual["rows"]), {"dbus"})
        self.assertNotIn("artifacts", actual)
        self.assertNotIn("withdrawal", actual["rows"]["dbus"])

    def test_manifest_exact_native_public_selector(self):
        selector = hook.manifest("unix:path=/tmp/bus")["rows"]["dbus"]["selector"]
        self.assertEqual(selector, {"idPrefix": "dbus:", "title": "EchoTags", "providerName": "org.rightclick.Pressure"})

    def test_array_encoding_and_expected_json_are_literal_and_exact(self):
        row = hook.manifest("unix:path=/tmp/bus")["rows"]["dbus"]
        self.assertEqual(json.loads(row["invoke"]["arguments"]["values"]), ["array", [["string", value] for value in hook.VALUES]])
        self.assertEqual(json.loads(row["invoke"]["expectedOutput"]), hook.VALUES)
        self.assertEqual(row["readback"], {"type": "returned-text", "expected": row["invoke"]["expectedOutput"]})
        self.assertIn("$(no-shell)", hook.VALUES[1])
        self.assertIn("no mutated-state", row["verificationBoundary"])

    def test_manifest_rejects_network_bus_or_newline(self):
        for address in ("tcp:host=example.org,port=1", "unix:path=/tmp/bus\nmalformed", None):
            with self.subTest(address=address), self.assertRaises(ValueError):
                hook.manifest(address)

    def test_argv_requires_actual_eight_and_withdraws_controlled_seven_only(self):
        argv = hook.command(pathlib.Path("/candidate"), pathlib.Path("/public"), pathlib.Path("/repo"), pathlib.Path("/private/manifest"),
            ["/venv/bin/python", "/component", "/wasmtime", "/wasm-tools"])
        self.assertEqual(argv[0], "/venv/bin/python")
        self.assertEqual(argv[argv.index("--manifest") + 1], "/private/manifest")
        required = [argv[index + 1] for index, value in enumerate(argv) if value == "--require"]
        verified = [argv[index + 1] for index, value in enumerate(argv) if value == "--require-verified"]
        withdrawn = [argv[index + 1] for index, value in enumerate(argv) if value == "--require-withdrawal"]
        self.assertEqual(required, [*hook.CONTROLLED, "dbus"])
        self.assertEqual(verified, required)
        self.assertEqual(withdrawn, list(hook.CONTROLLED))
        self.assertNotIn("--uid", argv)
        self.assertNotIn("--runtime-uid", argv)

    def test_venv_symlink_is_preserved_and_missing_tool_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            interpreter = root / "python"
            interpreter.write_text("public test-only executable"); interpreter.chmod(0o755)
            venv = root / "venv/bin"; venv.mkdir(parents=True)
            selected = venv / "python"; selected.symlink_to(interpreter)
            component = root / "component"; component.write_bytes(b"fixture")
            environment = dict(RIGHTCLICK_COEXISTENCE_PYTHON=str(selected), RIGHTCLICK_WASM_COMPONENT=str(component),
                RIGHTCLICK_WASM_RUNTIME=str(interpreter), RIGHTCLICK_WASM_TOOLS=str(interpreter))
            self.assertEqual(hook.selected_paths(environment)[0], selected)
            del environment["RIGHTCLICK_WASM_TOOLS"]
            with self.assertRaises(ValueError): hook.selected_paths(environment)

    def test_environment_drops_root_authority_and_scopes_readonly_git_exception(self):
        with mock.patch.dict(os.environ, {"HOME": "/root", "RIGHTCLICK_RCIR_CONFIG": "/secret/host", "DBUS_SESSION_BUS_ADDRESS": "wrong",
            "AWS_SECRET_ACCESS_KEY": "secret", "PYTHONPATH": "/untrusted", "GIT_CONFIG_VALUE_0": "*"}, clear=True):
            actual = hook.child_environment(pathlib.Path("/exact/repo"))
        self.assertEqual(actual["GIT_CONFIG_VALUE_0"], "/exact/repo")
        self.assertEqual(actual["GIT_OPTIONAL_LOCKS"], "0")
        self.assertEqual(actual["PYTHONDONTWRITEBYTECODE"], "1")
        self.assertFalse({"HOME", "RIGHTCLICK_RCIR_CONFIG", "DBUS_SESSION_BUS_ADDRESS", "AWS_SECRET_ACCESS_KEY", "PYTHONPATH"} & set(actual))

    def test_private_directory_and_config_use_fixed_writer_ownership(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(hook.os, "chown") as chown:
            directory = pathlib.Path(tmp) / "writer"
            hook.private_directory(directory)
            configuration = directory / "manifest.json"
            hook.private_file(configuration, b"{}")
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(configuration.stat().st_mode), 0o600)
            self.assertEqual(chown.call_args_list, [mock.call(directory, 1100, 1100), mock.call(configuration, 1100, 1100)])
            with self.assertRaises(FileExistsError): hook.private_file(configuration, b"replacement")

    def test_whole_helper_spawn_uses_writer_empty_groups_no_shell_and_finite_deadline(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(hook.os, "chown"), mock.patch.object(hook.os, "killpg", side_effect=ProcessLookupError), mock.patch.object(hook.subprocess, "Popen") as popen:
            process = popen.return_value; process.pid = 123; process.wait.return_value = 0; process.poll.return_value = 0
            self.assertEqual(hook.run_writer(["/venv/python", "/helper"], {"PATH": "/usr/bin"}, pathlib.Path(tmp) / "private.log"), 0)
            kwargs = popen.call_args.kwargs
            self.assertEqual((kwargs["user"], kwargs["group"], kwargs["extra_groups"]), (1100, 1100, []))
            self.assertTrue(kwargs["start_new_session"])
            self.assertNotIn("shell", kwargs)
            process.wait.assert_called_once_with(timeout=600)

    def test_timeout_cleans_entire_process_group_and_never_retries_effect(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(hook.os, "chown"), mock.patch.object(hook.os, "killpg") as killpg, mock.patch.object(hook.subprocess, "Popen") as popen:
            process = popen.return_value; process.pid = 123; process.poll.return_value = 0
            process.wait.side_effect = [subprocess.TimeoutExpired(["helper"], 600), 0, 0]
            with self.assertRaises(subprocess.TimeoutExpired):
                hook.run_writer(["helper"], {}, pathlib.Path(tmp) / "private.log")
            self.assertEqual(killpg.call_args_list, [mock.call(123, signal.SIGTERM), mock.call(123, signal.SIGKILL)])
            self.assertEqual(process.wait.call_args_list, [mock.call(timeout=600), mock.call(timeout=5), mock.call(timeout=5)])
            self.assertEqual(popen.call_count, 1)

    def test_check_accepts_only_truthfully_partial_eight_native_rows(self):
        hook.check_report(passing_report(), "binary")

    def test_check_rejects_forged_result_or_replaced_binary_or_platform(self):
        for field, value in (("binarySHA256", "other"), ("runtimePlatform", "macos"), ("singleClient", False),
            ("clientProcessCount", 2), ("status", "PASS_FOR_SUPPLIED_BOUNDARY"), ("canonicalOperations", sorted(hook.TOOLS) + ["dbus_execute"])):
            actual = passing_report(); actual[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): hook.check_report(actual, "binary")

    def test_check_rejects_node_claim_without_independent_observation_or_bound_receipt(self):
        for field in ("verified", "executionNodeVerified", "executed", "discovered"):
            actual = passing_report(); actual["rows"]["dbus"][field] = False
            with self.subTest(field=field), self.assertRaises(ValueError): hook.check_report(actual, "binary")
        actual = passing_report(); actual["rows"]["dbus"]["receipt"]["selectedCapabilityMatched"] = False
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")
        actual = passing_report(); actual["rows"]["dbus"]["independentObservation"]["kind"] = "http-json"
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")
        actual = passing_report(); actual["rows"]["dbus"]["independentObservation"] = {}
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")

    def test_check_rejects_claimed_dbus_withdrawal_or_absent_substrate_success(self):
        actual = passing_report(); actual["rows"]["dbus"]["liveWithdrawalTested"] = True
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")
        for family in ("macos", "kafka", "kubernetes"):
            actual = passing_report(); actual["rows"][family]["verified"] = True
            with self.subTest(family=family), self.assertRaises(ValueError): hook.check_report(actual, "binary")

    def test_check_requires_all_controlled_withdrawals_and_initial_same_graph(self):
        actual = passing_report(); actual["rows"]["wasm"]["liveWithdrawalTested"] = None
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")
        actual = passing_report(); actual["oneGraphSuppliedFamilies"].remove("dbus")
        with self.assertRaises(ValueError): hook.check_report(actual, "binary")

    def evidence(self, root, report=None):
        root.mkdir()
        (root / "results.json").write_text(json.dumps(report or passing_report()))
        (root / "trusted-public-key.raw").write_bytes(b"P" * 32)
        for name in ("results.json", "trusted-public-key.raw"): (root / name).chmod(0o600)

    def writer_fstat(self):
        original = os.fstat
        def as_writer(fd):
            actual = original(fd)
            return types.SimpleNamespace(st_mode=actual.st_mode, st_uid=1100, st_nlink=actual.st_nlink, st_size=actual.st_size)
        return mock.patch.object(hook.os, "fstat", side_effect=as_writer)

    def test_publication_copies_only_results_and_public_key_no_receipts_or_configs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / "source"; self.evidence(source)
            for name in ("host.json", "helper.log", "transcript.json", "key.raw", "success-receipt.json"):
                (source / name).write_text("secret must never be copied")
            with self.writer_fstat(): actual = hook.publish(source, root / "public", [b"private-secret"])
            self.assertEqual(actual["status"], "PARTIAL_BOUNDARY_PASS")
            self.assertEqual({p.name for p in (root / "public").iterdir()}, {"results.json", "trusted-public-key.raw"})

    def test_publication_rejects_secret_value_or_raw_receipt_payload(self):
        for report in (dict(passing_report(), detail="private-secret"), dict(passing_report(), receipt={"payload": "bytes"})):
            with tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp); source = root / "source"; self.evidence(source, report)
                with self.writer_fstat(), self.assertRaises(ValueError): hook.publish(source, root / "public", [b"private-secret"])
                self.assertFalse((root / "public").exists())

    def test_fifo_evidence_rejects_before_open_can_block(self):
        # A writer-controlled FIFO must not defeat the root evidence-reader
        # deadline before the non-regular-file fstat guard can run.
        with tempfile.TemporaryDirectory() as tmp:
            fifo = pathlib.Path(tmp) / "results.json"
            os.mkfifo(fifo, 0o600)
            program = (
                "import importlib.util, pathlib, sys\n"
                "spec=importlib.util.spec_from_file_location('hook',sys.argv[1])\n"
                "hook=importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)\n"
                "try: hook.private_read(pathlib.Path(sys.argv[2]),1024)\n"
                "except ValueError: print('NON_REGULAR_REJECTED')\n"
                "else: raise AssertionError('FIFO accepted')\n")
            result = subprocess.run([sys.executable, "-c", program, str(SCRIPTS / "ci/dbus-coexistence-hook.py"), str(fifo)],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=1, check=True)
            self.assertEqual(result.stdout.strip(), "NON_REGULAR_REJECTED")

    def test_publication_rejects_symlink_and_hardlink_sources(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / "source"; self.evidence(source)
            original = source / "results.json"; real = root / "real"; original.rename(real); original.symlink_to(real)
            with self.writer_fstat(), self.assertRaises(OSError): hook.publish(source, root / "public", [])
            original.unlink(); os.link(real, original)
            with self.writer_fstat(), self.assertRaises(ValueError): hook.publish(source, root / "public", [])

    def test_publication_rejects_wrong_owner_public_mode_oversize_and_bad_key_length(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp); source = root / "source"; self.evidence(source)
            # This isolated control intentionally runs as this test's current user.
            if os.geteuid() != 1100:
                with self.assertRaises(ValueError): hook.publish(source, root / "public", [])
            (source / "results.json").chmod(0o644)
            with self.writer_fstat(), self.assertRaises(ValueError): hook.publish(source, root / "public", [])
            (source / "results.json").chmod(0o600)
            with self.writer_fstat(), self.assertRaises(ValueError): hook.private_read(source / "results.json", 10)
            (source / "trusted-public-key.raw").write_bytes(b"P" * 31)
            with self.writer_fstat(), self.assertRaises(ValueError): hook.publish(source, root / "public", [])

    def test_optional_hook_is_before_original_owner_withdrawal_and_bus_policy_unchanged(self):
        source = (SCRIPTS / "acceptance-linux-dbus.py").read_text()
        self.assertLess(source.index('if args.coexistence:'), source.index('(root / "release-name").touch(); wait'))
        self.assertIn('if args.coexistence and args.expect_red:', source)
        self.assertIn('send_member="EchoTags"', source)
        self.assertNotIn('send_member="*"', source)
        self.assertIn('uid=1101)', source)
        self.assertIn('uid=1100)', source)


if __name__ == "__main__": unittest.main()
