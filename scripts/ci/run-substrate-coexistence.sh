#!/usr/bin/env bash
# Called after the candidate binary and genuine fixture toolchain are built.
# Native execution owns its private scratch; no relay or inbound MCP listener.
set -euo pipefail
binary="$1"
evidence="$2"
shift 2
: "${RIGHTCLICK_COEXISTENCE_PYTHON:?Provision an isolated Python with graphql-core, grpcio/reflection, MCP and cryptography}"
: "${RIGHTCLICK_WASM_RUNTIME:?Select the existing pinned actual native Wasmtime}"
: "${RIGHTCLICK_WASM_TOOLS:?Select the existing pinned actual native wasm-tools}"
: "${RIGHTCLICK_WASM_COMPONENT:?Select the existing actual fingerprint component}"
arguments=("$binary" "$evidence" --controlled --a2a --graphql-python "$RIGHTCLICK_COEXISTENCE_PYTHON"
  --grpc-python "$RIGHTCLICK_COEXISTENCE_PYTHON" --mcp-python "$RIGHTCLICK_COEXISTENCE_PYTHON"
  --component "$RIGHTCLICK_WASM_COMPONENT" --wasm-runtime "$RIGHTCLICK_WASM_RUNTIME" --wasm-tools "$RIGHTCLICK_WASM_TOOLS")
for family in openapi graphql grpc ard mcp a2a wasm; do
  arguments+=(--require "$family" --require-verified "$family" --require-withdrawal "$family")
done
"$RIGHTCLICK_COEXISTENCE_PYTHON" scripts/acceptance-substrate-coexistence.py "${arguments[@]}" "$@"
