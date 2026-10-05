# Yojam semantic limitation

Yojam 1.3.1 dynamically exposes `service:com.yojam.app:openURLViaService`. The supplied installation record changed the same URL query from 17 to 18 capabilities with no RIGHTCLICK acquisition changes. That historical before/after record was supplied by Ross; this reconstruction did not uninstall/reinstall Yojam to recreate it. Current discovery is retained in `evidence/v0.1-final/yojam/actions.json`.

The generic URL repair is commit `980c05e895ef6108be76b32e17289ea85a9bdb17`. It encodes compatible declared URL and text types, avoids using `public.file-url` for web URLs, and shares its encoding rule with applicability. The repaired remote invocation accepted the provider call but did not establish its external result. Ross's manual TextEdit → Services control opened the URL.

## One decisive control — 2026-10-05

The standalone harness in `evidence/v0.1-final/yojam/main.swift` is outside production. It reads the exact installed Service metadata, builds the exact URL `https://example.com/rightclick-yojam-proof`, uses only declared representations in declared order, invokes exactly once on the main thread from a running `NSApplication`, and strongly retains the named pasteboard and AppKit run loop for 30 seconds.

Declared order: `public.url`, `public.rtf`, `public.utf8-plain-text`, `NSStringPboardType`, `public.plain-text`. The URL strings and RTF text round-trip exactly. The provider is invoked with the discovered menu title “Open in Yojam”.

| Evidence stage | Result |
| --- | --- |
| DISCOVERED | PASS: installed metadata and current contextual query |
| APPLICABLE | PASS: supported declared encoding |
| PAYLOAD_BUILT | PASS: exact representations round-tripped |
| INVOKED | PASS: one `NSPerformService`, true |
| COMPLETED | UNKNOWN: provider does not expose a completion receipt |
| OUTCOME_VERIFIED | NO: no expected Yojam/browser outcome observed |

The pasteboard remained alive from 06:18:42Z through 06:19:13Z. Change count was 1 at invocation and 2 after retention. Neither this change nor the accepted call is semantic evidence. Independent observations showed Yojam Settings without the expected result and no proof URL in the browser tab inventory. Raw metadata and execution output are preserved beside the harness.

**The control did not pass semantic acceptance. The Services investigation stopped. No production repair was justified and no additional Yojam invocation or experiment matrix was run.** This does not establish that all generic AppKit invocations of this provider must fail; it establishes that this bounded control did not explain the working native-versus-generic differential.

## Inherited tentative change

The initial archive contained an uncommitted alternative `NSApplication.run` executor and an earlier chat claim that a harness had succeeded. That claim conflicts with the supplied handoff and lacked raw Yojam harness evidence in the repository. The full inherited source and patch are preserved under `evidence/v0.1-final/reconstruction/`. The unverified production change was removed in favour of the committed, BBEdit-proven engine. No provider-specific integration was added.

v0.1 ships with this limitation. BBEdit supplies the independent ordinary-install acquisition and semantic proof. Yojam supplies a second acquisition proof and a falsification of the claim that accepted invocation alone guarantees useful execution.
