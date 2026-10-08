# Frozen final release response compatibility — 2026-10-07

PASS: all nine response/auth/discovery controls preserve the actual immutable installed 0.2.2 baseline. The exact final release binary is `23d92e6319b299e2c3c47c3c1c0702b9c88eb37db413c533ae0846b9f5cd85fa`, with observed runtime version 0.2.3, platform macOS and authenticated HTTP transport. All seven public Core operations were exercised, and the tool list remained exactly seven.

The original actual baseline session was reused without another baseline invocation. Its SHA256 is `4ebfc7dd547355df5b11b6ec897786391c1c6d31951ed9da16d45e282211aaf9`; its recorded immutable installed binary SHA256 is `d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`. The source manifest, session digest, executable digest and seven-tool surface were checked before reuse. The baseline session is retained here byte-for-byte.

| Existing control | 0.2.2 and final release behavior | Fresh operation requests / writes |
| --- | --- | --- |
| Valid closed JSON body with enum | accepted; exact transmitted body, output and retained status preserved | 1 / 1 |
| Explicit operation security=[] clears inherited bearer requirement | accepted without provider Authorization; exact body/output/status preserved | 1 / 1 |
| Invalid enum | failed without output | 0 / 0 |
| Missing required field | failed without output | 0 / 0 |
| GET query capability unsupported | absent from catalogue; no invocation or status fabricated | 0 / 0 |
| Missing required provider bearer | unavailable without output | 0 / 0 |
| Malformed JSON response | failed without output after actual fixture write | 1 / 1 |
| Wrong response value type | failed without output after actual fixture write | 1 / 1 |
| HTTP503 provider rejection | rejected without output; fixture records no write | 1 / 0 |

Fresh totals are five operation requests and four fixture writes. Specification acquisitions are excluded from these operation counts. All invoked retained statuses match their records. Missing and wrong public HTTP access bearer return 401 and produce zero operation requests. The inherited provider-bearer declaration is overridden only by the existing explicit operation security=[] declaration; no provider credential is provisioned.

Each of the five dispatched candidate results has an independently verified Ed25519 receipt checked against the separately retained public pin, actual provider request task ID, lease ID and signed outcome. Fifteen further checks reject wrong public pin, task ID and lease ID (five each). Signed outcomes remain unverified, including the post-dispatch error controls. Signature validity authenticates runtime claims; the actual effect counts are separate observations from the owned fixture. In particular, a failed malformed/wrong-type result is not evidence of zero external effect.

Root provided build source `1b8dc070361f2a6205698b9a69e4323828eb2a8d`. Its Git Sources tree was independently read as `c7414e1dc9cf28c98262aa933e40166113f66ba8`; the only production diffs from bd5 are OpenAPIReflector credential-return guard and GRPCWireCodec bounds repair. Runtime provenance and pre/post-run file hashing both match the frozen binary. This audit did not rebuild or change that binary.

The probe has a small test-only extension for manifest-checked retained-baseline reuse and comparison of every prior state/output presence and request method/path/body/write/auth observation. The exact executed probe is retained losslessly as executed-probe.py.gz. No production, authority, credential guard or public tool changes were made. Disposable access bearer and signing private key/config were removed with the temporary fixture state; only a public key, generated task/lease IDs and safe owned records remain.

Remaining unproved here: actual provider credential-backed TLS on the public product path, issuer downscoping, authenticated subject/broker attachment, all-platform or all-substrate acceptance, and publication/tap installation. These controls do not establish those claims.
