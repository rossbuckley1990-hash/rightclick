# Native protected-reference pressure test

## Frozen REDs

1. **Substrate:** native Windows 2022, actual production C backend. **Generic deficiency:** ordinary object creation does not guarantee that a protected runtime object belongs to the current principal. Ordinary files/directories had `ownerMatchesCurrentUser=0`; explicit-owner controls had `1`. **Reusable primitive:** private, create-new, current-principal object provisioning. **Thin host layer:** Windows security descriptor supplied at native creation, behind the shared artifact/reference boundary. **Required GREEN:** real native private creation/read plus existing-path refusal, broader-read/null-DACL/junction controls; full Windows runtime acceptance remains required. **Cross-substrate benefit:** signers, policy references, observer references and artifact snapshots all share the same provisioning invariant.

2. **Substrate:** native Windows 2022. **Generic deficiency:** the selected path and final handle path were compared using different short/long name representations, denying legitimate objects even with correct private authority. At exact source `f871102ba519b89970e5b7216e75e6c181c17dff`, all four `finalPathMatches=0`; correctly owned controls still returned harden/read denial. At exact diagnostic source `2dd7bd2fafbbaa994812d1bc904730b74aa74816`, all four independently reported `longPathMatches=1`, `longPathChanged=1`, `expectedHasShortAlias=1`. **Reusable primitive:** compare the lexical long component names of the selected path with the independently opened final handle, while retaining redirect refusal. **Thin host layer:** native Windows path representation normalization. **Required GREEN:** real native protected reads plus parent-junction denial and no widened owner/DACL acceptance. **Cross-substrate benefit:** the shared protected-reference and immutable artifact primitives become usable on another native host without changing the agent ABI.

3. **Substrate:** native Windows source review, independently flagged by the security agent. **Generic deficiency:** file handles used to set read-only attributes did not explicitly request the read-attribute access required by the native query. **Reusable primitive:** acquire the exact handle rights needed by the operation. **Thin host layer:** explicit `FILE_READ_ATTRIBUTES` on creation/hardening handles. **Required GREEN:** actual native harden/private-read controls; source review alone cannot prove this gate. **Cross-substrate benefit:** the same host primitive protects every runtime consumer.

`red/` and `diagnostic/` contain exact raw observations, source identities and backend/probe hashes. The first two workflows succeeded as diagnostics; they did not demonstrate a working protected runtime. No host paths, principals, credentials or SID bytes are exported by the observation probe. Cleanup reports command acknowledgements only.

## Product impact

1. Installation still produces one `rightclick` executable; no additional package is introduced.
2. No new user-visible concept or agent operation is introduced.
3. Creation, native representation and protection complexity stay behind the host boundary.
4. All provider compilers reuse the same file/reference boundary.
5. Runtime-owned snapshots are provisioned automatically; existing operator references must already satisfy private authority.
6. This removes a measured native-host blocker; successful clean installation and real execution within minutes still need demonstration.

Candidate repair is not an accepted portable release. The existing seven operations, strict owner/DACL checks and independent verification requirements remain the acceptance conditions.

The candidate also pins a bounded set of native ancestor handles before private object creation, rejects reparse ancestors before creating any target, refuses overwrite/adoption, and disposes failed newly created files through their original handles. Native controls require zero file/directory entries through a parent junction and independent removal after a READONLY-only attribute release. Mac shared regression: 43 executed, zero failures/skips. Native Windows candidate results are pending.

Limits remain explicit: native directory creation followed by opening its handle has a failure window with an unknown leftover; no path-based removal is attempted for an unconfirmed object. Ancestor sharing constraints do not establish security against a compromised same-owner host, kernel, or every possible parent delete-child race. Those stronger race claims need independent native adversarial evidence.
