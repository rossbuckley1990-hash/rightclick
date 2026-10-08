import hashlib, json, os, time
from wasmtime import Store, Module, Instance

task_id = os.environ["TASK_ID"]
agent = os.environ["ASSIGNED_AGENT"]
start = int(os.environ["START"])
end = int(os.environ["END"])
expected_sha = os.environ["MODULE_SHA"]
delay = float(os.environ.get("DELAY", "0"))

with open("/capsule.wasm", "rb") as f:
    wasm_bytes = f.read()
actual_sha = hashlib.sha256(wasm_bytes).hexdigest()
if actual_sha != expected_sha:
    raise SystemExit(f"module hash mismatch: {actual_sha} != {expected_sha}")

time.sleep(delay)
store = Store()
module = Module(store.engine, wasm_bytes)
instance = Instance(store, module, [])
fn = instance.exports(store)["sum_squares"]
result = int(fn(store, start, end))
input_hash = hashlib.sha256(f"{start}:{end}".encode()).hexdigest()
output_hash = hashlib.sha256(str(result).encode()).hexdigest()

print(json.dumps({
    "task_id": task_id,
    "agent": agent,
    "start": start,
    "end": end,
    "result": result,
    "module_sha256": actual_sha,
    "input_hash": input_hash,
    "output_hash": output_hash,
    "runtime": "wasmtime-python"
}, sort_keys=True), flush=True)
