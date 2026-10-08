#!/usr/bin/env bash
# Fixture controller owns Docker; the RIGHTCLICK executor has only scoped files.
set -euo pipefail
image="$1"
inputs="$RUNNER_TEMP/rightclick-runtime-inputs"
tools="$RUNNER_TEMP/rightclick-proof-tools"
control="$RUNNER_TEMP/rightclick-kafka-mutation"
evidence="evidence/proof-lab"
mkdir -m 700 "$control"
controller_pid=''
cleanup_controller() {
  if [[ -n "$controller_pid" ]]; then
    if kill -0 "$controller_pid" 2>/dev/null; then kill "$controller_pid"; fi
    wait "$controller_pid" || true
  fi
}
trap cleanup_controller EXIT
execute() {
  docker run --rm --network host --cap-drop ALL --security-opt no-new-privileges:true \
    --memory 12g --cpus 4 --pids-limit 1024 --read-only \
    --tmpfs "/tmp:rw,nosuid,nodev,size=512m,mode=1777" \
    --tmpfs "/home/rcproof:rw,nosuid,nodev,size=256m,uid=$(id -u),gid=$(id -g),mode=0700" \
    --mount "type=bind,src=$GITHUB_WORKSPACE,dst=/workspace" \
    --mount "type=bind,src=$inputs,dst=/runtime-inputs,readonly" \
    --mount "type=bind,src=$tools,dst=/proof-tools,readonly" \
    --mount "type=bind,src=$control,dst=/mutation-control" \
    -e RIGHTCLICK_KAFKA_CLIENT=/proof-tools/rpk \
    -e RIGHTCLICK_KAFKA_PUBLISHER_CONFIG=/runtime-inputs/kafka-publisher.json \
    -e RIGHTCLICK_KAFKA_OBSERVER_CONFIG=/runtime-inputs/kafka-observer.json \
    -e RIGHTCLICK_KAFKA_STABILITY=1 \
    -e RIGHTCLICK_KAFKA_STABILITY_EVIDENCE=/workspace/evidence/proof-lab/kafka-stability \
    -e RIGHTCLICK_KAFKA_TEST_EVIDENCE=/workspace/evidence/proof-lab/kafka-native-effects.json \
    -e RIGHTCLICK_KUBERNETES_CLIENT=/proof-tools/kubectl \
    -e RIGHTCLICK_TEST_KUBERNETES_WRITER_CONFIG=/runtime-inputs/scoped.kubeconfig \
    -e RIGHTCLICK_TEST_KUBERNETES_OBSERVER_CONFIG=/runtime-inputs/observer.kubeconfig \
    "$image" "$@"
}
execute bash scripts/ci/run-fixture-tests.sh \
  'KafkaCapabilityTests|KafkaAcquisitionStabilityTests|KubernetesCapabilityArtifactTests' \
  "$evidence/native-tests.log" "$evidence/native-outcomes.json" \
  --require-class KafkaCapabilityTests --require-class KafkaAcquisitionStabilityTests \
  --require-class KubernetesCapabilityArtifactTests

# Only now start the external owner controller; no Docker socket/authority is
# mounted into the product. Handshakes bind the existing broker container ID.
python3 scripts/proof-lab/kafka-withdrawal-controller.py --control "$control" \
  --evidence "$evidence/kafka-withdrawal-controller.json" --timeout 900 &
controller_pid=$!
for attempt in $(seq 1 100); do
  if [[ -f "$control/controller-ready" ]]; then break; fi
  kill -0 "$controller_pid"
  sleep 0.1
done
test -f "$control/controller-ready"
execute /opt/rightclick-verifier/bin/python scripts/acceptance-kafka.py .build/release/rightclick \
  "$evidence/kafka-product" --client /proof-tools/rpk \
  --publisher-config /runtime-inputs/kafka-publisher.json \
  --observer-config /runtime-inputs/kafka-observer.json --mutation-directory /mutation-control
wait "$controller_pid"
controller_pid=''
execute /opt/rightclick-verifier/bin/python scripts/acceptance-kubernetes.py .build/release/rightclick \
  "$evidence/kubernetes-product" --lab /runtime-inputs --client /proof-tools/kubectl

# One additional client owns a single combined graph, including the exact scoped
# broker and namespace. The fixture owner still retains all administration.
execute bash -euo pipefail -c '
  export RIGHTCLICK_COEXISTENCE_PYTHON=/opt/rightclick-verifier/bin/python
  export RIGHTCLICK_WASM_RUNTIME=/proof-tools/components/wasmtime-v49.0.2-x86_64-linux/wasmtime
  export RIGHTCLICK_WASM_TOOLS=/proof-tools/components/wasm-tools-1.261.0-x86_64-linux/wasm-tools
  export RIGHTCLICK_WASM_COMPONENT=/proof-tools/fingerprint.component.wasm
  manifest="$(mktemp /tmp/rightclick-scoped-coexistence.XXXXXXXX)"
  trap '\''rm -f -- "$manifest"'\'' EXIT
  "$RIGHTCLICK_COEXISTENCE_PYTHON" scripts/ci/make-scoped-coexistence-manifest.py \
    /runtime-inputs "$manifest" --rpk /proof-tools/rpk --kubectl /proof-tools/kubectl
  bash scripts/ci/run-substrate-coexistence.sh .build/release/rightclick \
    evidence/proof-lab/coexistence --manifest "$manifest" \
    --require kafka --require kubernetes --require-verified kafka --require-verified kubernetes
'
