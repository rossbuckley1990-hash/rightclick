# Disposable universal-runtime pressure-test lab

This lab provisions real Linux, Kafka, Kubernetes and native Windows substrates.
Its setup and independent checks are infrastructure controls, **not** the final
fresh-agent proof. The seven-operation runtime acceptance stays RED until an
agent restricted to those operations discovers, explains, authorizes, invokes,
verifies and receipts each capability and exercises live graph mutation.

## Reproduce Linux, Kafka and Kubernetes

Docker, Python 3, kind and kubectl must be available. The default node image is
pinned to kind's documented v1.36.1 digest. An existing cached official image can
be selected explicitly with `--kind-image`; preserve its exact digest as evidence.

```sh
proof_state=$(mktemp -d /tmp/rightclick-proof-XXXXXX)
python3 scripts/proof-lab/lab.py up --state "$proof_state" --evidence /tmp/rightclick-provisioning.json
python3 scripts/proof-lab/lab.py verify --state "$proof_state" --evidence /tmp/rightclick-readiness.json
python3 scripts/proof-lab/lab.py down --state "$proof_state" --evidence /tmp/rightclick-teardown.json
```

Listeners bind only to host loopback: Linux 19141, Kafka 19092, Kubernetes 16443.
Linux runs as UID 1000 with dropped capabilities, a read-only root filesystem,
4 MiB private effect tmpfs and 64 MiB memory limit. Kafka uses a genuine Redpanda
broker, topic `rightclick.proof`, and distinct SCRAM publisher/observer identities
with write/describe and read/describe ACLs respectively. Publishing to
`rightclick.forbidden` must be denied. Kubernetes is cluster `rightclick-proof`,
namespace `rightclick-proof`, with a service account permitted only to create,
get, update, patch and delete ConfigMaps in that namespace. The token expires in
one hour. A separately issued observer identity can only get ConfigMaps in that
namespace and must be denied mutation. Nodes and ConfigMaps in another namespace
must be actually Forbidden. `renew-authority --state "$proof_state"` issues fresh
one-hour writer and observer credentials without widening their authority.

All secrets and kubeconfigs remain in the private temporary state directory.
Evidence includes credential references, authority and expiry, never credentials.
Teardown verifies the exact proof ownership label before removing any container.
It never prunes images, removes unrelated containers, or modifies a default
kubeconfig. Provisioning failure may leave owned resources so diagnostics remain
available; run `down` before retrying `up`.

The readiness verifier distinguishes acceptance from observation: Linux HTTP 202
is compared with a separate container file read; Kafka producer ACK is compared
with a separately authenticated consumer record containing topic, partition,
offset, nonce and payload; Kubernetes creation is compared with a separately
issued get-only observer's readback of the actual resource UID, resource version
and data. The administrator is solely the isolated bootstrap issuer, never the
runtime or observer identity.

## Native Windows

The `native-windows` job creates a disposable non-administrator local account on
an isolated Windows runner, grants it access to its proof directory, and launches
the same descriptor-driven host service under that account. The independent
observer reads its Windows effect and verifies the deterministic challenge hash.
The service must be denied reading an administrator-only guard file. An invalid
service token must return 401. The process is then stopped and its endpoint must
disappear. The identity, private configuration and files are removed in `finally`.

This demonstrates real Windows infrastructure and authority controls. It does
not connect Windows into the simultaneous eleven-substrate provider graph, build
RIGHTCLICK for Windows, or demonstrate seven-operation live withdrawal. Those
requirements remain RED until separately evidenced.

## Architectural REDs exposed by these substrates

| Substrate | Generic runtime deficiency under test | Reusable primitive | Thin provider layer | Evidence that turns RED GREEN | Reuse |
| --- | --- | --- | --- | --- | --- |
| Linux | Host assumptions must not prevent descriptor-driven remote execution or independent effect observation | Portable execution target and pinned observer contract | HTTP OpenAPI acquisition of the isolated host service | Seven-operation discovery/run/status plus independently read Linux effect and integrity-backed receipt | Windows and other remote hosts |
| Kafka | Accepted event publication cannot imply semantic verification; event identity and deferred status must survive polling | Deferred execution lifecycle plus immutable event correlation and independent observer contract | Kafka protocol producer and consumer transport with topic-scoped SCRAM credential references | Runtime execution nonce matches an independently consumed topic/partition/offset/payload, with forbidden topic denied and live provider disappearance | A2A tasks, queue/stream systems |
| Kubernetes | Desired state acceptance cannot imply observed state; credentials must bind exact granted authority | Scoped credential reference, external authority evidence, control-plane observation and deferred verification | Kubernetes API discovery and namespace-scoped resource transport | Runtime mutation followed by independent UID/resourceVersion/data readback; actual cluster-wide Forbidden; unavailable authority fails closed | A2A delegation, cloud control planes |
| Windows | Remote host liveness and native identity cannot be inferred from a Linux container or ACK | Portable execution target, host provenance and live provider refresh | Same host descriptor/effect fixture under a restricted Windows local principal | Native Windows effect/denial control, then restricted runtime graph withdraws its capabilities without changing seven-operation ABI | Linux and disconnected remote hosts |

Infrastructure GREEN alone does not turn any runtime row GREEN. The local Docker
OOM/timeouts and Kubernetes reserved-label bootstrap failure were observed lab
REDs and fixed at the provisioning layer; they are not claimed as universal runtime
improvements.

Official provisioning references:
[kind configuration](https://kind.sigs.k8s.io/docs/user/configuration/),
[Redpanda quickstart](https://docs.redpanda.com/streaming/current/get-started/quick-start/),
[Kubernetes service accounts](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/).
