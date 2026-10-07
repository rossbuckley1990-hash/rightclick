# Reliability candidate 0.1.1

This review branch repairs generic defects before a new capability-engine freeze. It is not a published replacement for 0.1.0 and does not satisfy the broader G1–G14 goal yet.

Setup rejects malformed or non-object client configuration without overwriting it, preserves unrelated entries, and returns failure when a required setup stage fails. The native isolated control reproduced 12 failed cases before repair and passed all 18 afterwards; six native XCTest methods cover the same boundary.

Reflected text-return metadata cannot establish a harmless operation. All unknown Services require confirmation. Security and code-execution hints raise conservative risk classifications. These classifications do not themselves prove effects. The former text-transform test is deliberately strengthened to require confirmation; no assertion was weakened to hide the defect.

The candidate enforces documented Service context conditions. Conditions inside a dictionary are combined; alternative dictionaries are evaluated separately. Selection-language/script restrictions and unknown conditions abstain. File-path context uses the path, rather than file contents. Only supported declared representations are encoded. Ambiguous Service names/identifiers remain discoverable with unsupported invocation. The public title-based API is not used to guess which provider to call. See [Apple’s Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html).

Provider invocation acceptance is `accepted`, not semantic success. Sharing completion callbacks also remain provider-reported evidence. Unchanged pasteboard input is never returned as provider output. Rejection and deadline uncertainty are distinct. A caller’s explicit exact returned-text postcondition can establish `succeeded`/`VERIFIED` only when declared provider-written output differs from known input and matches that postcondition. Its evidence boundary excludes external side effects. Rewritten input, a changed counter, and matching strings without input provenance remain unverified.

Runtime diagnostics are opt-in via `RIGHTCLICK_DIAGNOSTIC_LOG`. The routine no longer writes payload readback or automatically appends runtime diagnostics to the repository. Historical logs are preserved.

The native full suite passes 57 tests. The production release binary passes stdio and authenticated loopback HTTP checks. See [raw regression evidence](../evidence/north-star/reliability/) and [the gate ledger](../evidence/north-star/gate-ledger.json) for scope and outstanding work. These checks use a local candidate; they do not establish public installation, real-client holdouts, or participant reproduction.

The MCP `confirmed` argument still needs a real human approval boundary before the next freeze. Freshness, metadata provenance, transport-equivalence acceptance, privacy-conscious metrics, fresh holdouts and the consenting participant run remain unfinished. The historical BBEdit proof and Yojam semantic limitation retain their original verdicts. CotEditor exposed the context defect and is a development case, never a repaired blind pass.

Version 0.1.1 source packaging is deterministic. The previous published bottle is excluded from a different version. Modified source still cannot be packaged against the published 0.1.0 bottle pin. Existing public release bytes and the public tap remain unchanged.
