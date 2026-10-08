# Stranger's Software Challenge: live acceptance specification

**Status: NOT RUN.** This document defines a next acceptance experiment; it is
not evidence that the demonstration has succeeded.

## Useful goal

Turn a non-sensitive dataset into a web-ready report, preserve the original,
publish only the approved report to an authorized staging destination, and
independently verify the persisted report. Never transmit the raw dataset.
The goal must not name providers or prescribe a workflow.

## Freeze and eligibility

Freeze and record the RIGHTCLICK executable hash, source commit, model/client
configuration, seven tool definitions, initial discovery inventory and success
predicates. An independent operator then chooses a provider inside a declared,
supported protocol/schema envelope. Record all setup, consent and manual
interventions. Normal discovery configuration and credential setup are allowed
but are not advertised as "zero setup". No provider-specific RIGHTCLICK edits,
new agent tools, hidden shell/SDK escape, or replacement model instructions.
Do not weaken the confirmation contract for the demo.

A new service instance and a fresh nonce generated after the freeze ensure the
outcome depends on new state. Eligibility is not a promise of arbitrary-app
compatibility. Do not retrofit an adapter to make a failed provider count.

## Sequence and decisive checks

| Stage | Action | Required observation |
|---|---|---|
| Absent | Start without the publishing provider | Capability absent; no claimed publication |
| Acquire | Independent operator exposes the eligible contract through a supported discovery source | Same running agent can inspect its actual schema, identity and authority requirements |
| Compose | Agent prepares the report using discovered capabilities | Original hash preserved; fresh output readable and matches declared data checks |
| Churn | Remove a planned provider before its next invocation | Rediscovery selects an eligible alternative or explicitly stops; no blind stale-ID call |
| Ambiguity | Introduce two distinct same-title capabilities | No implicit first-match dispatch; request an exact ID |
| Invalid input | Omit a required argument | Rejection before consent and provider execution |
| Approve | Present the exact destination and approved report | Explicit valid authorization; raw dataset stays local |
| False success | Disposable test provider acknowledges but does not persist | Provider acceptance is not reported as verified publication |
| Normal success | Authorized write persists the report | Separate read-back observes nonce, content and digest at the intended resource |

The false-success variant must use an owned disposable fixture, clearly marked
as such. Do not tamper with third-party production services. Do not retry
ambiguous writes automatically. Missing independent read-back means UNVERIFIED,
not SUCCESS. A pre-existing file or a writer echoing the requested digest is
not sufficient. A digest verifies bytes at an observation boundary, not the
honesty of every component or complete causal attribution.

## Evidence

Preserve the unedited execution trace, capability contracts, output artifacts,
original/output digests, approval records with secrets omitted, provider-side
request counters, and independently collected read-back. Record failures,
unsupported contracts and manual repairs as outcomes. Hashing sensitive data
is not a promise of anonymization; use non-sensitive fixtures.

Publish separately:
- setup and integration work;
- completion and adaptation results;
- false-success detection;
- unauthorized-dispatch count;
- full token/context usage, not merely top-level tool count.

No hidden provider-specific SDK/network calls may perform the hard step outside
RIGHTCLICK. Local compute through a discovered capability is allowed; using
that compute capability as a secret network transport is not.

## Fair comparison

Compare against the same model with a competent dynamic-tool/OpenAPI setup as
well as a conventional setup. Give comparable preparation, contract access,
credentials and approval boundaries. Record preparation cost and maintenance
work after the provider changes. Do not claim that dynamic discovery alone is
unique, or that seven tools imply constant context cost.

## Deferred claims

This experiment does not prove arbitrary-provider universality, commercial
advantage, autonomous approval, signed leases or full remote federation. The
current first federation slice uses explicitly configured loopback peers;
remote trust is a separate gate. Linux helper tests are not proof of the full
macOS runtime operating on Linux. Native and real-service runs remain required.
