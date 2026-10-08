"""Test-only helper controls and actual fixture wire protocols; no Swift/product run."""
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
import urllib.request

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("coexistence", SCRIPTS / "acceptance-substrate-coexistence.py")
proof = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proof)


class Helpers(unittest.TestCase):
    def test_exact_substitution_preserves_integer_type(self):
        self.assertEqual(proof.substitute({"offset": "${offset}", "argv": "prefix-${offset}"}, {"offset": 3}), {"offset": 3, "argv": "prefix-3"})

    def test_fresh_binding_controls_do_not_reuse_payload(self):
        first, second = proof.fresh_bindings(), proof.fresh_bindings()
        self.assertNotEqual(first["nonce"], second["nonce"])
        self.assertNotEqual(first["value"], second["value"])
        self.assertEqual(second["fnv"], proof.fnv32(second["nonce"]))
        self.assertEqual(second["sha256Value"], proof.sha(second["value"].encode()))

    def test_algorithm_known_vector(self):
        self.assertEqual(proof.fnv32(""), "2166136261")
        self.assertEqual(proof.fnv32("hello"), "1335831723")

    def test_result_binding_limits_acknowledgement_keys(self):
        result = {"executionId": "execution", "rcir": {"taskID": "task", "leaseID": "lease"}, "output": json.dumps({"topic": "proof", "offset": 12, "value": "provider-altered-value", "password": "hidden"})}
        actual = proof.result_bindings({"nonce": "nonce", "value": "original-desired-value"}, result)
        self.assertEqual(actual["taskID"], "task")
        self.assertEqual(actual["offset"], 12)
        self.assertNotIn("password", actual)
        self.assertEqual(actual["value"], "original-desired-value")

    def test_selector_is_specific(self):
        action = {"id": "graphql:id:storeProof", "title": "GraphQL mutation: storeProof", "provider": {"name": "GraphQL provider"}}
        self.assertTrue(proof.matches(action, {"idPrefix": "graphql:", "idSuffix": ":storeProof", "title": "GraphQL mutation: storeProof", "providerName": "GraphQL provider"}))
        self.assertFalse(proof.matches(action, {}))
        self.assertFalse(proof.matches(action, {"idPrefix": "grpc:"}))
        self.assertFalse(proof.matches(action, {"metadata": {"substrate": "graphql", "field": "storeProof"}}))
        self.assertFalse(proof.matches(action, {"unsupported": "must-never-match-all"}))

    def test_all_controlled_selectors_match_real_public_view_without_metadata(self):
        # Public payload deliberately omits metadata, matching CapabilityView's
        # actual Codable fields. These shapes reproduce the initial product
        # failure even though protocol fixture tests were green.
        class ManifestOnlyPorts:
            def start(self, label, *_args):
                return {"http": "18001", "observer": "18002", "grpc": "18003"}[label]
        args = types.SimpleNamespace(graphql_python="unused", grpc_python="unused")
        manifest, _ = proof.controlled_fixtures(args, pathlib.Path("/tmp"), ManifestOnlyPorts())
        identities = {
            "openapi": ("openapi:provider:operation:storeOpenapi", "Store disposable openapi proof", "Coexistence openapi"),
            "graphql": ("graphql:provider:operation:storeProof", "GraphQL mutation: storeProof", "GraphQL provider"),
            "grpc": ("grpc:provider:operation:rightclick.coexistence.Proof.Store", "gRPC rightclick.coexistence.Proof/Store", "gRPC 127.0.0.1:18003"),
            "ard": ("ard:coexistence-registry:openapi:provider:operation:storeArd", "Store disposable ard proof", "Coexistence ard")}
        for family, (identity, title, provider) in identities.items():
            action = {"id": identity, "title": title, "provider": {"name": provider}, "source": "system", "inputTypes": ["public.plain-text"], "requiresConfirmation": True}
            selector = manifest["rows"][family]["selector"]
            with self.subTest(family=family):
                self.assertNotIn("metadata", action)
                self.assertTrue(proof.matches(action, selector))
                self.assertFalse(proof.matches(dict(action, id="other:" + identity), selector))
                self.assertFalse(proof.matches(dict(action, title="GraphQL query: storeProof" if family == "graphql" else "Different operation"), selector))
                self.assertFalse(proof.matches(dict(action, provider={"name": provider + "-wrong-node"}), selector))
                self.assertFalse(proof.matches(dict(action, provider=None), selector))
        grpc_action = {"id": "grpc:provider:operation:rightclick.coexistence.Proof.Echo", "title": "gRPC rightclick.coexistence.Proof/Echo", "provider": {"name": "gRPC 127.0.0.1:18003"}}
        self.assertFalse(proof.matches(grpc_action, manifest["rows"]["grpc"]["selector"]))

    def test_owned_a2a_selector_binds_exact_public_endpoint_identity_without_metadata(self):
        class ManifestOnlyPorts:
            def start(self, label, *_args):
                return {"a2a-agent": "18004", "a2a-observer": "18005"}[label]
        with tempfile.TemporaryDirectory() as temporary:
            manifest = {"rows": {}, "a2aAgentCards": []}
            args = types.SimpleNamespace(repository=pathlib.Path("/unused/repository"))
            proof.add_owned_a2a(manifest, args, pathlib.Path(temporary), ManifestOnlyPorts())
            action = {"id": "a2a:" + proof.sha(b"http://127.0.0.1:18004/a2a") + ":delegate", "title": "Delegate a task to RIGHTCLICK disposable delegated agent", "provider": {"name": "RIGHTCLICK disposable delegated agent"}}
            selector = manifest["rows"]["a2a"]["selector"]
            self.assertTrue(proof.matches(action, selector))
            other = dict(action, id="a2a:" + proof.sha(b"http://127.0.0.1:18006/a2a") + ":delegate")
            self.assertFalse(proof.matches(other, selector))

    def test_manifest_rejects_authority_expansion(self):
        for key in ["RIGHTCLICK_RCIR_CONFIG", "RIGHTCLICK_LINK_ENABLED", "HOME", "RIGHTCLICK_RUNTIME_ID"]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.checked_manifest({"environment": {key: "forbidden"}})

    def test_manifest_rejects_nonstring_env_and_unknown_family(self):
        with self.assertRaises(ValueError):
            proof.checked_manifest({"environment": {"RIGHTCLICK_KUBERNETES_NAMESPACE": ["wrong"]}})
        with self.assertRaises(ValueError):
            proof.checked_manifest({"rows": {"fabricated": {"selector": {"id": "a"}}}})

    def test_manifest_rejects_wrong_uid(self):
        with self.assertRaises(ValueError):
            proof.checked_manifest({"runtimeUID": os.geteuid() + 1})

    def test_manifest_rejects_unbound_selector(self):
        with self.assertRaises(ValueError):
            proof.checked_manifest({"rows": {"wasm": {"selector": {}}}})

    def test_authority_environment_removal_restores_ambient(self):
        original = dict(os.environ)
        try:
            os.environ.update(RIGHTCLICK_RCIR_CONFIG="unsafe-ambient", DBUS_SESSION_BUS_ADDRESS="ambient-session", COEXISTENCE_KEEP="yes")
            with proof.isolated_authority_environment():
                self.assertNotIn("RIGHTCLICK_RCIR_CONFIG", os.environ)
                self.assertNotIn("DBUS_SESSION_BUS_ADDRESS", os.environ)
                self.assertEqual(os.environ["COEXISTENCE_KEEP"], "yes")
            self.assertEqual(os.environ["RIGHTCLICK_RCIR_CONFIG"], "unsafe-ambient")
        finally:
            os.environ.clear()
            os.environ.update(original)

    def test_private_configuration_mode_and_bounds(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "private.json"
            proof.private_json(path, {"version": 1})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                proof.private_json(path, {"oversized": "a" * 262144})

    def test_missing_evidence_does_not_infer_implementation_or_compilation(self):
        args = types.SimpleNamespace(registration_evidence=None, registration_log=None, registration_test_gate=None, compile_evidence=None)
        implemented, compiled = proof.compilation_rows(args, "a" * 40, True)
        self.assertIsNone(implemented)
        self.assertTrue(all(value is None for value in compiled.values()))

    def test_registration_file_alone_is_not_passing_evidence(self):
        args = types.SimpleNamespace(registration_evidence="file", registration_log=None, registration_test_gate=None, compile_evidence=None)
        implemented, _ = proof.compilation_rows(args, "a" * 40, True)
        self.assertIsNone(implemented)

    def test_registered_evidence_is_pinned_to_source_process_and_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            evidence, log, gate = root / "registered.json", root / "test.log", root / "gate.json"
            identity = "testRequiredSubstratesRemainRegisteredInActualRuntimeComposition"
            text = "Test Case '-[RightClickMCPTests.SubstrateInventoryTests " + identity + "]' passed (0.001 seconds).\n"
            log.write_text(text)
            evidence.write_text(json.dumps({"families": list(proof.FAMILIES), "canonicalOperations": ["context_runtime", "context_inspect", "context_actions", "context_explain", "context_run", "context_run_status", "context_providers"]}))
            value = {"status": "passed", "testedSourceHead": "a" * 40, "testExitCode": 0, "logSHA256": proof.sha(log.read_bytes())}
            gate.write_text(json.dumps(value))
            args = types.SimpleNamespace(registration_evidence=evidence, registration_log=log, registration_test_gate=gate, compile_evidence=None)
            implemented, _ = proof.compilation_rows(args, "a" * 40, True)
            self.assertEqual(implemented, dict.fromkeys(proof.FAMILIES, True))
            for modified in [dict(value, testedSourceHead="b" * 40), dict(value, testExitCode=1), dict(value, logSHA256="0" * 64)]:
                gate.write_text(json.dumps(modified))
                with self.subTest(modified=modified), self.assertRaises(ValueError):
                    proof.compilation_rows(args, "a" * 40, True)

    def test_compile_evidence_cannot_promote_dirty_or_wrong_head(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "source.json").write_text(json.dumps({"candidateSHA": "a" * 40}))
            (root / "build-RightClickProviders.log").write_text("Build of target: 'RightClickProviders' complete! (1s)\n")
            args = types.SimpleNamespace(registration_evidence=None, registration_log=None, registration_test_gate=None, compile_evidence=root)
            _, compiled = proof.compilation_rows(args, "a" * 40, True)
            self.assertTrue(compiled["graphql"])
            self.assertIsNone(compiled["ard"])
            self.assertIsNone(compiled["dbus"])
            for head, clean in [("b" * 40, True), ("a" * 40, False)]:
                with self.subTest(head=head, clean=clean), self.assertRaises(ValueError):
                    proof.compilation_rows(args, head, clean)

    def test_file_absence_control_rejects_effect_and_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            selected = {"type": "owned-file", "relative": "effect"}
            proof.absence_read(selected, root, {})
            (root / "effect").write_text("unexpected mutation")
            with self.assertRaises(ValueError):
                proof.absence_read(selected, root, {})
            with self.assertRaises(ValueError):
                proof.absence_read({"type": "owned-file", "relative": "../outside"}, root, {})

    def test_component_absence_cannot_use_admitted_lease(self):
        spec = {"type": "returned-text"}
        proof.absence_read(spec, pathlib.Path("/tmp"), {}, {"state": "unavailable"})
        for result in [{"output": "0"}, {"rcir": {"leaseConsumed": True}}]:
            with self.subTest(result=result), self.assertRaises(ValueError):
                proof.absence_read(spec, pathlib.Path("/tmp"), {}, result)

    def test_json_observation_handles_literal_dotted_annotation_key(self):
        raw = json.dumps({"metadata": {"annotations": {"rightclick.io/invocation": "task"}}, "partition": 0}).encode()
        proof.compare_json_fields(raw, [{"path": ["metadata", "annotations", "rightclick.io/invocation"], "expected": "task"}, {"path": ["partition"], "expected": 0}])
        with self.assertRaises(ValueError):
            proof.compare_json_fields(raw, [{"path": ["partition"], "expected": 1}])

    def test_observer_reference_rejects_origin_substitution_before_reading_token(self):
        with self.assertRaises(ValueError):
            proof.read_http("http://127.0.0.1:2/observe/a", "/absent/private-token", "http://127.0.0.1:1")

    def test_observer_reference_rejects_public_cleartext_origin(self):
        with self.assertRaises(ValueError):
            proof.read_http("http://untrusted.invalid/observe/a", "/absent/private-token", "http://untrusted.invalid")

    def test_observer_reference_rejects_world_readable_symlink_and_oversized_tokens(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "token"
            path.write_text("private-fixture-token")
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                proof.read_http("http://127.0.0.1:1", str(path), "http://127.0.0.1:1")
            path.chmod(0o600)
            symlink = pathlib.Path(temporary) / "link"
            symlink.symlink_to(path)
            with self.assertRaises(OSError):
                proof.read_http("http://127.0.0.1:1", str(symlink), "http://127.0.0.1:1")
            path.write_text("a" * 4097)
            with self.assertRaises(ValueError):
                proof.read_http("http://127.0.0.1:1", str(path), "http://127.0.0.1:1")

    def test_scoped_lab_adapter_excludes_admin_and_raw_credential_bytes(self):
        module_spec = importlib.util.spec_from_file_location("scoped", SCRIPTS / "ci/make-scoped-coexistence-manifest.py")
        scoped = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(scoped)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            config = {"clusters": [{"cluster": {"server": "https://127.0.0.1:16443"}}], "contexts": [{"context": {"namespace": "rightclick-proof"}}]}
            writer = dict(config, users=[{"user": {"token": "scoped-writer-token"}}])
            observer = dict(config, users=[{"user": {"token": "scoped-get-only-token"}}])
            for name, value in [("scoped.kubeconfig", writer), ("observer.kubeconfig", observer), ("kafka-publisher.json", {"user": "publisher", "password": "publisher-private"}), ("kafka-observer.json", {"user": "reader", "password": "reader-private"})]:
                proof.private_json(root / name, value)
            value = scoped.build(root, pathlib.Path(sys.executable), pathlib.Path(sys.executable))
            proof.checked_manifest(value)
            output = json.dumps(value)
            for secret in ("scoped-writer-token", "scoped-get-only-token", "publisher-private", "reader-private", "admin.kubeconfig"):
                self.assertNotIn(secret, output)
            self.assertEqual(set(value["rows"]), {"kafka", "kubernetes"})
            writer["contexts"][0]["context"]["namespace"] = "default"
            proof.private_json(root / "scoped.kubeconfig", writer)
            with self.assertRaises(ValueError):
                scoped.build(root, pathlib.Path(sys.executable), pathlib.Path(sys.executable))

    def test_native_mac_row_selects_real_service_and_does_not_claim_withdrawal(self):
        module_spec = importlib.util.spec_from_file_location("native_mac", SCRIPTS / "ci/make-native-mac-coexistence-manifest.py")
        native_mac = importlib.util.module_from_spec(module_spec)
        module_spec.loader.exec_module(native_mac)
        value = proof.checked_manifest(native_mac.manifest())
        row = value["rows"]["macos"]
        self.assertEqual(row["selector"]["id"], "service:com.apple.ChineseTextConverterService:convertTextToFullWidth")
        self.assertEqual(row["item"], "RightClick123")
        self.assertEqual(row["invoke"]["expectedOutput"], "ＲｉｇｈｔＣｌｉｃｋ１２３")
        self.assertNotIn("withdrawal", row)

    def test_external_withdrawal_command_is_never_accepted(self):
        with self.assertRaises(ValueError):
            proof.withdraw({"type": "command", "argv": ["docker", "stop", "arbitrary"]}, pathlib.Path("/tmp"), None)

    def test_noncanonical_tools_cannot_be_called(self):
        client = types.SimpleNamespace(canonical_names={"context_run"})
        with self.assertRaises(ValueError):
            proof.call_allow_error(client, "kafka_publish", {})


class WireFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        required = ("COEXISTENCE_GRAPHQL_PYTHON", "COEXISTENCE_GRPC_PYTHON", "COEXISTENCE_MCP_PYTHON")
        if any(not os.environ.get(name) for name in required):
            raise unittest.SkipTest("Genuine fixture interpreters were not explicitly provisioned")
        cls.temporary = tempfile.TemporaryDirectory(prefix="rightclick-wire-only-")
        cls.root = pathlib.Path(cls.temporary.name).resolve()
        cls.root.chmod(0o700)
        cls.processes = proof.Processes(cls.root)
        try:
            cls.http = cls.processes.start("http", [os.environ[required[0]], str(SCRIPTS / "coexistence-fixture.py"), str(cls.root), "http"], cls.root / "http-port", True)
            cls.observer = cls.processes.start("observer", [sys.executable, str(SCRIPTS / "coexistence-fixture.py"), str(cls.root), "observer"], cls.root / "observer-port", True)
            cls.grpc = cls.processes.start("grpc", [os.environ[required[1]], str(SCRIPTS / "coexistence-fixture.py"), str(cls.root), "grpc"], cls.root / "grpc-port")
            cls.mcp = cls.processes.start("mcp", [os.environ[required[2]], str(SCRIPTS / "coexistence-fixture.py"), str(cls.root), "mcp"], cls.root / "mcp-port", True)
        except Exception:
            cls.processes.close()
            cls.temporary.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        try:
            cls.processes.close()
        finally:
            cls.temporary.cleanup()

    def post(self, path, value):
        request = urllib.request.Request("http://127.0.0.1:" + self.http + path, data=json.dumps(value).encode(), headers={"Content-Type": "application/json"})
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=3) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            error.close()
            raise

    def observe(self, family, nonce):
        return "http://127.0.0.1:" + self.observer + "/observe/" + family + "/" + nonce

    def test_actual_openapi_contract_mutation_and_separate_observation(self):
        spec = json.loads(proof.read_http("http://127.0.0.1:" + self.http + "/openapi.json"))
        self.assertEqual(spec["paths"]["/store/openapi"]["post"]["operationId"], "storeOpenapi")
        bound = proof.fresh_bindings()
        control = {"type": "http-text", "url": self.observe("openapi", bound["nonce"]), "expected": bound["value"]}
        proof.absence_read(control, self.root, bound)
        self.post("/store/openapi", {"challenge": bound["nonce"], "value": bound["value"]})
        proof.independent_read(control, {}, self.root, bound)
        with self.assertRaises(ValueError):
            proof.absence_read(control, self.root, bound)

    def test_actual_graphql_parser_introspection_validation_and_mutation(self):
        reflection = self.post("/graphql", {"query": "{ __schema { mutationType { fields { name } } } }"})
        self.assertEqual(reflection["data"]["__schema"]["mutationType"]["fields"][0]["name"], "storeProof")
        self.assertIn("errors", self.post("/graphql", {"query": "mutation { nonexistent }"}))
        bound = proof.fresh_bindings()
        query = "mutation Proof($challenge:String!,$value:String!){storeProof(challenge:$challenge,value:$value){challenge value}}"
        actual = self.post("/graphql", {"query": query, "variables": {"challenge": bound["nonce"], "value": bound["value"]}})
        self.assertEqual(actual["data"]["storeProof"]["value"], bound["value"])
        self.assertEqual(proof.read_http(self.observe("graphql", bound["nonce"])).decode(), bound["value"])

    def test_actual_ard_search_and_live_registry_withdrawal(self):
        actual = self.post("/ard/search", {"query": {"text": "find disposable store"}})
        self.assertEqual(actual["results"][0]["type"], "application/openapi+json")
        spec = json.loads(proof.read_http(actual["results"][0]["url"]))
        self.assertIn("/store/ard", spec["paths"])
        proof.withdraw({"type": "owned-marker", "marker": "withdraw-ard"}, self.root, self.processes)
        self.assertEqual(self.post("/ard/search", {"query": {"text": "find store"}}), {"results": []})
        self.assertEqual(json.loads(proof.read_http(actual["results"][0]["url"]))["paths"], {})

    def test_actual_grpc_reflection_and_unary_effect(self):
        bound = proof.fresh_bindings()
        script = '''import grpc,sys
from google.protobuf import descriptor_pb2,descriptor_pool,message_factory
from grpc_reflection.v1alpha import reflection_pb2,reflection_pb2_grpc
channel=grpc.insecure_channel("127.0.0.1:"+sys.argv[1]); grpc.channel_ready_future(channel).result(timeout=3)
stub=reflection_pb2_grpc.ServerReflectionStub(channel)
rows=list(stub.ServerReflectionInfo(iter([reflection_pb2.ServerReflectionRequest(file_containing_symbol="rightclick.coexistence.Proof")]),timeout=3))
files=rows[0].file_descriptor_response.file_descriptor_proto
pool=descriptor_pool.DescriptorPool()
for encoded in files: pool.AddSerializedFile(encoded)
request=message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.coexistence.StoreRequest"))
response=message_factory.GetMessageClass(pool.FindMessageTypeByName("rightclick.coexistence.StoreResponse"))
method=channel.unary_unary("/rightclick.coexistence.Proof/Store",request_serializer=lambda v:v.SerializeToString(),response_deserializer=response.FromString)
actual=method(request(challenge=sys.argv[2],value=sys.argv[3]),timeout=3)
assert actual.challenge==sys.argv[2] and actual.value==sys.argv[3]
channel.close()
'''
        completed = subprocess.run([os.environ["COEXISTENCE_GRPC_PYTHON"], "-c", script, self.grpc, bound["nonce"], bound["value"]], capture_output=True, timeout=10)
        self.assertEqual(completed.returncode, 0, "gRPC fixture probe failed; private diagnostics withheld")
        self.assertEqual(proof.read_http(self.observe("grpc", bound["nonce"])).decode(), bound["value"])

    def test_actual_official_mcp_sdk_dispatch_and_independent_observation(self):
        bound = proof.fresh_bindings()
        script = '''import asyncio,sys
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client
async def probe():
 async with streamable_http_client("http://127.0.0.1:"+sys.argv[1]+"/mcp") as (read,write,_):
  async with ClientSession(read,write) as session:
   await session.initialize(); tools=await session.list_tools()
   assert [tool.name for tool in tools.tools]==["record_challenge"]
   actual=await session.call_tool("record_challenge",{"challenge":sys.argv[2]})
   assert not actual.isError and actual.structuredContent=={"challenge":sys.argv[2]}
asyncio.run(probe())
'''
        completed = subprocess.run([os.environ["COEXISTENCE_MCP_PYTHON"], "-c", script, self.mcp, bound["nonce"]], capture_output=True, timeout=10)
        self.assertEqual(completed.returncode, 0, "MCP fixture probe failed; private diagnostics withheld")
        self.assertEqual(proof.read_http(self.observe("mcp", bound["nonce"])).decode(), bound["nonce"])

    def test_malformed_oversized_request_never_creates_observed_effect(self):
        bound = proof.fresh_bindings()
        with self.assertRaises(urllib.error.HTTPError):
            self.post("/store/openapi", {"challenge": bound["nonce"], "value": "a" * 8193})
        proof.absence_read({"type": "http-text", "url": self.observe("openapi", bound["nonce"])}, self.root, {})


if __name__ == "__main__":
    unittest.main()
