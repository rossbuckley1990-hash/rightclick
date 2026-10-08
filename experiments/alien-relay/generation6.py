import hashlib
import inspect
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time
import urllib.request

from PIL import Image
from huggingface_hub import HfApi
import huggingface_hub

ROOT = pathlib.Path("alien-proof")
ROOT.mkdir(parents=True, exist_ok=True)
GRADIO = str(pathlib.Path(sys.executable).with_name("gradio"))
OBSERVED_AT = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
REPO_SHA = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
RUNNER_OS = os.environ.get("RUNNER_OS", "unknown")
RUNNER_ARCH = os.environ.get("RUNNER_ARCH", "unknown")

def run(cmd, timeout=60, stdout_path=None, stderr_path=None):
    cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if stdout_path:
        pathlib.Path(stdout_path).write_text(cp.stdout, encoding="utf-8", errors="replace")
    if stderr_path:
        pathlib.Path(stderr_path).write_text(cp.stderr, encoding="utf-8", errors="replace")
    return cp

def load_json_text(text):
    try:
        return json.loads(text)
    except Exception:
        return None

def type_text(obj):
    try:
        return json.dumps(obj, sort_keys=True).lower()
    except Exception:
        return str(obj).lower()

def is_file_param(param):
    t = type_text(param.get("type", {}))
    return "filepath" in t or "filedata" in t

def is_string_return(ret):
    t = type_text(ret.get("type", {}))
    return '"string"' in t or "string" == str(ret.get("type", "")).lower()

SKILL_COMMIT = "ca0325bb20b2d0a1b2efa893670c4c72f79e707b"
SKILL_URL = f"https://raw.githubusercontent.com/huggingface/skills/{SKILL_COMMIT}/skills/huggingface-gradio/SKILL.md"
skill_bytes = urllib.request.urlopen(SKILL_URL, timeout=30).read()
skill_text = skill_bytes.decode("utf-8", errors="replace")
(ROOT / "huggingface-gradio-SKILL.md").write_text(skill_text, encoding="utf-8")
skill_sha = hashlib.sha256(skill_bytes).hexdigest()
skill_ok = "gradio info" in skill_text and "gradio predict" in skill_text and "gradio.FileData" in skill_text

flux_info_cp = run([GRADIO, "info", "black-forest-labs/FLUX.2-dev"], timeout=90,
                   stdout_path=ROOT / "flux-info.json", stderr_path=ROOT / "flux-info.err")
flux_info = load_json_text(flux_info_cp.stdout)
flux_endpoint = flux_info.get("/infer") if isinstance(flux_info, dict) else None
flux_schema_ok = False
if isinstance(flux_endpoint, dict):
    params = flux_endpoint.get("parameters", [])
    returns = flux_endpoint.get("returns", [])
    flux_schema_ok = (
        any(p.get("name") == "prompt" and p.get("required") is True and "string" in type_text(p.get("type", {})) for p in params)
        and any(r.get("name") == "Result" and "filepath" in type_text(r.get("type", {})) for r in returns)
    )

flux_prompt = "A luminous relay beacon floating above a vast cloud datacenter at blue hour, surreal science-fiction atmosphere, intricate light trails, no people, no text"
flux_payload = {
    "prompt": flux_prompt,
    "input_images": [],
    "seed": 424242,
    "randomize_seed": False,
    "width": 512,
    "height": 512,
    "num_inference_steps": 8,
    "guidance_scale": 4,
    "prompt_upsampling": False,
}
flux_predict_cp = run(
    [GRADIO, "predict", "black-forest-labs/FLUX.2-dev", "/infer", json.dumps(flux_payload, separators=(",", ":"))],
    timeout=240,
    stdout_path=ROOT / "flux-result.json",
    stderr_path=ROOT / "flux-result.err",
)
flux_result = load_json_text(flux_predict_cp.stdout)

candidate_paths = []
returned_seed = None
def walk_files(value):
    global returned_seed
    if isinstance(value, dict):
        for k, v in value.items():
            if str(k).lower() == "seed" and isinstance(v, (int, float)):
                returned_seed = v
            walk_files(v)
    elif isinstance(value, list):
        for v in value:
            walk_files(v)
    elif isinstance(value, str):
        p = pathlib.Path(value)
        if p.exists() and p.is_file():
            candidate_paths.append(p)
walk_files(flux_result)

image_evidence = {"found": False}
generated_image = None
for p in candidate_paths:
    try:
        with Image.open(p) as im:
            fmt = im.format
            width, height = im.size
            im.verify()
        data = p.read_bytes()
        dest = ROOT / ("generation5-object" + (p.suffix or ".bin"))
        shutil.copy2(p, dest)
        generated_image = dest
        image_evidence = {
            "found": True,
            "source_path": str(p),
            "artifact_path": str(dest),
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "width": width,
            "height": height,
            "format": fmt,
            "pil_verify": True,
        }
        break
    except Exception:
        continue

image_verified = (
    image_evidence.get("found") is True
    and image_evidence.get("pil_verify") is True
    and image_evidence.get("width") == 512
    and image_evidence.get("height") == 512
    and isinstance(image_evidence.get("bytes"), int)
    and image_evidence["bytes"] > 1000
)

space_methods = sorted(
    name for name, member in inspect.getmembers(HfApi)
    if "space" in name.lower() and callable(member)
)
list_spaces_member = getattr(HfApi, "list_spaces", None)
list_spaces_signature = str(inspect.signature(list_spaces_member)) if callable(list_spaces_member) else None
environment_discovery_ok = "list_spaces" in space_methods and callable(list_spaces_member)

api = HfApi()
queries = ["image captioning", "image caption", "visual question answering"]
discovered_spaces = []
search_errors = []
seen = set()
if environment_discovery_ok:
    for query in queries:
        try:
            try:
                results = list(api.list_spaces(search=query, sort="likes", direction=-1, limit=20))
            except TypeError:
                results = list(api.list_spaces(search=query, limit=20))
            for item in results:
                sid = getattr(item, "id", None)
                if sid and sid not in seen:
                    seen.add(sid)
                    discovered_spaces.append({"id": sid, "query": query})
        except Exception as exc:
            search_errors.append({"query": query, "error": repr(exc)})

(ROOT / "space-discovery.json").write_text(json.dumps({
    "huggingface_hub_version": getattr(huggingface_hub, "__version__", "unknown"),
    "discovered_methods": space_methods,
    "list_spaces_signature": list_spaces_signature,
    "queries": queries,
    "spaces": discovered_spaces,
    "errors": search_errors,
}, indent=2, sort_keys=True), encoding="utf-8")

inspection = []
selected = None
for entry in discovered_spaces[:18]:
    sid = entry["id"]
    try:
        cp = run([GRADIO, "info", sid], timeout=30)
        info = load_json_text(cp.stdout)
        record = {"space": sid, "query": entry["query"], "exit_status": cp.returncode, "stderr": cp.stderr[-1000:]}
        if cp.returncode != 0 or not isinstance(info, dict):
            record["reason"] = "info_failed_or_non_json"
            inspection.append(record)
            continue
        record["endpoints"] = sorted(info.keys())
        for endpoint, contract in info.items():
            if not isinstance(contract, dict):
                continue
            params = contract.get("parameters", [])
            required = [p for p in params if p.get("required") is True]
            required_file = [p for p in required if is_file_param(p)]
            other_required = [p for p in required if not is_file_param(p)]
            returns = contract.get("returns", [])
            if len(required_file) == 1 and not other_required and any(is_string_return(r) for r in returns):
                selected = {
                    "space": sid,
                    "query": entry["query"],
                    "endpoint": endpoint,
                    "input_parameter": required_file[0].get("name"),
                    "contract": contract,
                }
                record["selected_endpoint"] = endpoint
                break
        inspection.append(record)
        if selected:
            break
    except subprocess.TimeoutExpired:
        inspection.append({"space": sid, "query": entry["query"], "reason": "info_timeout"})
    except Exception as exc:
        inspection.append({"space": sid, "query": entry["query"], "reason": "inspection_exception", "error": repr(exc)})

(ROOT / "space-inspection.json").write_text(json.dumps(inspection, indent=2, sort_keys=True), encoding="utf-8")

invocation = None
text_observation = None
if selected and generated_image is not None:
    payload = {
        selected["input_parameter"]: {
            "path": str(generated_image.resolve()),
            "meta": {"_type": "gradio.FileData"},
        }
    }
    try:
        cp = run(
            [GRADIO, "predict", selected["space"], selected["endpoint"], json.dumps(payload, separators=(",", ":"))],
            timeout=180,
            stdout_path=ROOT / "understanding-result.json",
            stderr_path=ROOT / "understanding-result.err",
        )
        parsed = load_json_text(cp.stdout)
        strings = []
        def collect_strings(value, key=None):
            if isinstance(value, dict):
                for k, v in value.items():
                    collect_strings(v, k)
            elif isinstance(value, list):
                for v in value:
                    collect_strings(v, key)
            elif isinstance(value, str):
                s = value.strip()
                low = s.lower()
                if len(s) >= 5 and not low.startswith(("http://", "https://", "/", "file:")):
                    strings.append({"key": key, "text": s})
        collect_strings(parsed if parsed is not None else cp.stdout)
        if strings:
            strings.sort(key=lambda x: len(x["text"]), reverse=True)
            text_observation = strings[0]
        invocation = {
            "exit_status": cp.returncode,
            "payload_shape": {selected["input_parameter"]: {"path": "<generated-image>", "meta": {"_type": "gradio.FileData"}}},
            "returned": parsed if parsed is not None else cp.stdout[-4000:],
            "text_candidates": strings[:10],
        }
    except subprocess.TimeoutExpired:
        invocation = {"exit_status": 124, "error": "predict_timeout"}
    except Exception as exc:
        invocation = {"exit_status": 125, "error": repr(exc)}

text_verified = (
    invocation is not None
    and invocation.get("exit_status") == 0
    and isinstance(text_observation, dict)
    and len(text_observation.get("text", "").strip()) >= 5
)

plausibility_terms = ["cloud", "sky", "blue", "light", "building", "city", "beacon", "datacenter", "data center"]
matched_terms = []
if text_observation:
    low = text_observation["text"].lower()
    matched_terms = [term for term in plausibility_terms if term in low]

semantic_success = (
    skill_ok
    and flux_info_cp.returncode == 0
    and flux_schema_ok
    and flux_predict_cp.returncode == 0
    and image_verified
    and environment_discovery_ok
    and bool(discovered_spaces)
    and selected is not None
    and text_verified
)

proof = {
    "experiment": "RIGHTCLICK Alien Relay Generation 6",
    "observed_utc": OBSERVED_AT,
    "repository_commit_sha": REPO_SHA,
    "runner": {"os": RUNNER_OS, "arch": RUNNER_ARCH},
    "procedure": "skills/rightclick/procedures/recursive-capability-expansion.v1.json",
    "recursive_path": [
        "ChatGPT seven generic RIGHTCLICK operations",
        "RIGHTCLICK reflected GitHub OpenAPI provider",
        "GitHub-hosted Ubuntu runner",
        "compiled RIGHTCLICK ARD probe",
        "Hugging Face ARD discovery",
        "huggingface-gradio application/ai-skill",
        "Gradio protocol learned from immutable skill artifact",
        "FLUX.2-dev contract introspected and image generated",
        "installed environment inspected for Space-discovery capability",
        "image-understanding Spaces discovered at runtime",
        "one safe file-to-text contract selected from live schemas",
        "generated image submitted to the newly discovered remote AI service",
        "textual observation independently read back",
    ],
    "learned_procedure": {
        "source_commit": SKILL_COMMIT,
        "source_url": SKILL_URL,
        "sha256": skill_sha,
        "contains_info_predict_filedata": skill_ok,
    },
    "generation5_object": {
        "flux_info_exit_status": flux_info_cp.returncode,
        "flux_schema_valid": flux_schema_ok,
        "flux_predict_exit_status": flux_predict_cp.returncode,
        "returned_seed": returned_seed,
        "image": image_evidence,
    },
    "environment_capability_discovery": {
        "huggingface_hub_version": getattr(huggingface_hub, "__version__", "unknown"),
        "space_related_methods": space_methods,
        "list_spaces_signature": list_spaces_signature,
        "discovery_ok": environment_discovery_ok,
        "search_queries": queries,
        "candidate_count": len(discovered_spaces),
        "search_errors": search_errors,
    },
    "selected_remote_capability": selected,
    "invocation": invocation,
    "independent_postcondition": {
        "rule": "remote invocation exits zero and returns a non-path textual observation of at least five characters",
        "observed": text_verified,
        "text_observation": text_observation,
        "plausibility_terms_matched": matched_terms,
    },
    "semantic_success": semantic_success,
}
(ROOT / "rightclick-alien-proof.json").write_text(json.dumps(proof, indent=2, sort_keys=True), encoding="utf-8")
print(json.dumps(proof, indent=2, sort_keys=True))

if not semantic_success:
    sys.exit(3)
