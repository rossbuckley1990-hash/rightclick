# Native Windows integrated RED triage

The failing candidate is PR49
`e09f0179f738189fb30b87c652a5433fba648054`; freshly read main is
`33fc2c33f70445e47104c4e8abc0d91987ec2b4e`. The native protected-reference
gate passes nine tests. The integrated run executes 512 tests with 78 skips,
81 failures and 68 unexpected failures. Its complete job, artifact test logs,
source/toolchain provenance and affected original source are losslessly frozen
in `evidence/windows-integrated-triage-20261007/red-e09` before repair.
These are separate gates; nine protected-file passes do not make Windows GREEN.

## Pressure map

| Substrate exposing RED | Generic runtime or fixture deficiency | Reusable primitive | Thin Windows layer | Evidence required for GREEN | Other-substrate benefit |
| --- | --- | --- | --- | --- | --- |
| Native Windows real HTTP lifecycle/observer tests throw missing-file errors | Shared fixture lookup assumes case-sensitive `PATH`; three suites additionally execute literal Unix Python paths. Exact original environment/interpreter cause is not yet measured | One installed-interpreter fixture selector and reproducible explicit CI provisioning | Windows-only case-insensitive environment lookup; pinned native Python 3.12 provision; pre-provisioning standalone diagnostic records only key spelling/presence, candidate count and interpreter availability | Actual native diagnostic plus the unchanged real HTTP/observer tests and seven-operation transport gate on the new exact head | Shared A2A, OpenAPI, authority, signer and independent-observation fixtures reach the same runtime on each host |
| Native Windows executable pool controls throw Code513 | Fixture hardens ordinarily created objects whose token-default owner need not equal the current user | Existing atomic private-directory/file construction, immutable snapshot pool and explicit owned read-only release | Existing HostFiles creation/release APIs; no owner-adoption or privilege broadening | Five original native content-change/withdrawal/race/budget controls pass without changing their assertions | Reuses the same immutable host executable snapshot boundary used by Kafka and other bounded child transports |
| Native Windows stdin/deadline/protected-reference tests fail before reaching the intended boundary | Fixtures execute `/bin/cat` and `/usr/bin/true` and assign POSIX modes on Windows | Existing bounded process, protected-reference and redirect denial primitives | Installed native Python equivalents; current-user private synthetic references; real native junction and broader-read negative controls | Native exact-byte stdin echo, literal shell-shaped data, size/deadline rejection, child exit without stdin read, protected positive and redirected/broader-authority negative controls | Preserves shared child-transport controls and existing Unix test executables |
| Native Windows Kubernetes controlled invocation reports `invalidDescriptor` | Resolver still rejects drive-qualified operator-selected paths even though the common path boundary already supports them | Reuse `RuntimePlatform.isAbsolutePath` at the existing resolver admission edge | One predicate substitution; relative and drive-relative client paths remain denied before file/process access | Actual native controlled typed invocation plus relative-path negative controls; genuine cluster/native final acceptance remains separate | Removes one Unix-specific assumption using the same path boundary already used by snapshots/protected references |
| Native Windows invocation-binding fixture fails before its causal controls | A copied Unix shebang is not a native Windows executable; POSIX-only fake credential protection cannot establish authority | Existing descriptor/typed transport/host marker/independent causal observation boundary | A compiled test-only native launcher preserves argv/stdin/stdout while selecting the installed Python and owned script; dispatch uses no shell. Controlled credentials use the existing private-file API | Native stale Kafka/Kubernetes marker rejection and fresh-marker controls retain their existing assertions | The same bounded transport and causal binding primitives are tested on another host; this fixture never claims a genuine broker or cluster |
| Native Windows disk experience test throws `unsafeStorage` | Protected durable experience storage is explicitly unavailable on Windows | A shared protected, bounded, crash-safe multi-process durable storage boundary is still required | No new ledger or plaintext fallback in this patch; coordinate the journal/Host lane | Existing disk persistence and safety assertions must genuinely pass on the supported backend | A common durable storage primitive can support both advisory experience and runtime recovery with distinct authority roles |
| Native Windows NULL-DACL test passes without recording the actual descriptor state | Exit zero or blank SDDL cannot distinguish present+NULL from an empty ACL | Independent native descriptor classification through `GetSecurityDescriptorDacl` and `GetAclInformation` | Test-only native API observation after the exact PowerShell recipe, with explicit native NULL and empty-DACL contrast | Actual descriptor read/present/null/defaulted/ACE-count records, alongside protected-read denial; until observed, the recipe's NULL claim remains RED | Prevents filesystem authority tests from accepting a different ACL shape than the adversarial boundary they intend |

## Boundaries

HostFiles and the Experience implementation are unchanged. No assertion is
removed, changed to success, or skipped. Private construction does not adopt
existing objects. Explicit read-only release is limited to owned fixture files;
actual source bytes are still revalidated on every snapshot acquisition and
return. Provider metadata, policy, credentials, signer keys and acquisition
results are not cached by these changes.

The native launcher is a controlled test transport, not a Windows substrate
reflector and not a new AI operation. Genuine Windows acquisition remains the
programme Windows lane's responsibility. Its compiled bytes and launcher path
are selected by the test host; the underlying script continues to emit the
same controlled metadata and stale/fresh host markers. No broker, cluster or
shared credential is modified. These controls never establish genuine Kafka
or Kubernetes acceptance.

The installed RIGHTCLICK connection remains Stable 0.2.2, PID 67552, SHA-256
`d31419fafc96e08c4a2db9d1b389320acb2835c1a901597244249772d7ac489d`.
Personally queried runtime/providers and applicable actions report 42 providers
and 264 actions for the selected context, with no discovered procedural-memory
capability. A dynamically discovered repository-workflow capability was
explained. The canonical seven operation names and the actual responses are
retained in the self-use evidence. No new candidate primitive is represented as
installed, and no executable procedural-memory use is claimed.

Native Windows repair verification, Linux/Windows integrated convergence,
Experience persistence, distribution and the eleven-substrate goal remain RED
until their actual evidence passes. The new pre-provisioning diagnostic must run
before CI changes its interpreter environment, preserving causal attribution.

The native descriptor probe follows the documented output-validity boundary:
`daclPresent=true` together with a NULL pointer is a NULL DACL, whereas a
non-NULL ACL with zero measured ACEs is empty. When presence or descriptor read
is false, pointer/defaulted outputs are reported as unavailable rather than
inventing a NULL state. See Microsoft's
[GetSecurityDescriptorDacl documentation](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-getsecuritydescriptordacl)
and the native
[SetNamedSecurityInfoW](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setnamedsecurityinfow)
and [GetNamedSecurityInfoW](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getnamedsecurityinfow)
API declarations. These establish interpretation of the measured fields, not
the actual state produced by the PowerShell recipe; that still needs live data.

Shared Mac controls on repair source `c570ce9` pass 42 tests with two existing
absent-WASM fixture skips and no failures. A separate actual HTTP/authority/
causality/observation/deferred run passes all 41 tests, including all ten A2A
lifecycle tests. The standalone Swift diagnostic compiles locally, but its
Windows API execution and native client compilation remain pending actual CI.
These local results do not upgrade the native Windows gate. The required bottle
comparison still exits 1; release alignment belongs to the programme release lane.
