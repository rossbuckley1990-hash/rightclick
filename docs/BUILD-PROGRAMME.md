# RIGHTCLICK build programme: verified capability experience

Baseline: b6439f116af2bb19c7a02b816be0d4391ac087ee (2026-10-07).
Branch: feature/verified-capability-experience-001.

## North star

Agents acquire useful capabilities from their environment, complete authorised
work, verify explicitly defined outcomes, and benefit from previous experience
without inheriting stale authority. Seven generic MCP operations remain intact.

## Delivery 1: capability experience (this change)

An opt-in local ledger records an execution UUID, a SHA-256 contract fingerprint,
a closed outcome category and observation time. The fingerprint binds the fresh
capability (including routing, advertised schemas and authority requirements) and
a configured namespace. Existing discovery and execution remain authoritative.

Both synchronous CapabilityEngine.run and terminal CapabilityEngine.begin results
feed the learner. context_explain exposes advisory counts on currently discovered
contracts. Acceptance is not counted as verified success. Even a verified flag
requires nonempty, evaluated, passing structured predicates before the learner
records predicatesVerified. This describes those historical predicates only, not
universal reliability, provider trust, semantic equivalence or a new outcome.

No prompts, input arguments, output values, tokens, provider instructions or
executable recipes are stored. Hashes are not an anonymisation guarantee for
private capability catalogs; do not publish the ledger. There is no telemetry,
central registry, external model call, training job or shared data network.

Configuration (experimental; not installed automatically):

    RIGHTCLICK_EXPERIENCE_DIRECTORY=/absolute/canonical/private/directory
    RIGHTCLICK_EXPERIENCE_NAMESPACE=an-opaque-workspace-identifier

Both variables are required. The parent must already exist. New directory mode is
0700; existing directories must be owned by this user with no group/other access.
Files are 0600, protected against symlink/hardlink redirection, size limited and
replaced atomically under a nonblocking process lock. Retention defaults to 512
executions and seven days; explicit API bounds are 1,024 and 30 days. Busy, unsafe
or corrupt storage cannot bypass execution checks. No shell command is run by the
learning component. Corrupt data is not silently overwritten. The Swift ledger
API provides forgetAll(); stop participating runtimes before manual removal.

Limits: this is NOT a durable execution journal, crash reconciliation, autonomous
recipe synthesis, semantic goal retrieval, shared learning, a trusted approval
service or a guarantee that provider implementation has not changed. Async runs
which remain started when begin returns are not learned in this first slice.
Legacy returned-text-only postconditions are conservatively recorded as accepted
rather than structured-predicate evidence. Contract changes invalidate the match;
permissions and availability must still be checked on every run. The namespace
is isolation input, not authenticated tenant identity. Multi-user deployments
must separate storage and namespaces at a trusted boundary.

## Ordered delivery gates

1. EXPERIENCE-001: local experience and adversarial regression tests. Prove cold
   run -> observation -> warm explanation; drift -> no inherited history; revoked
   permission -> no invocation. Full macOS CI and unchanged seven-tool acceptance
   are required before merge. Linux component tests are not full runtime proof.
2. AUTHORITY-002: trusted short-lived grants binding principal, operation, contract,
   arguments, resource, policy epoch and destination. Validate expiry, revocation,
   argument substitution and replay. Discovery disclosure needs its own policy.
   Keep grants separate from memory. Do not build a new identity platform.
3. JOURNAL-003: durable execution states and authorised independent read-back;
   crash before/after provider commit; do not blindly repeat uncertain mutations.
   Never claim universal exactly-once execution or automatic rollback.
4. EVAL-004: independently selected tasks/contracts, frozen runtime, strong curated
   integration and direct-code baselines. Measure supported/unsupported counts,
   verified outcomes, wrong-success reports, latency, tokens and human effort.
   Author-produced fixtures are regression tests, not independent market evidence.
5. PORTABLE-005: separate headless execution/policy core from native adapters;
   prove equivalent remote workflow controls on Linux and macOS. No language
   rewrite, marketplace or SDK catalog without demonstrated demand.
6. RECIPE-006: bounded typed recipes and provider substitution only after the
   previous gates; live revalidation, fresh grants and fresh verification remain
   mandatory. Local first. Shared sanitized learning requires opt-in and evidence
   of cross-user benefit; never pool private workflows or authority.

## Value and moat gates

Memory by itself is copyable. The intended advantage is less integration and
recovery work per verified authorised outcome, reinforced by customer workflow,
external conformance contributions and embedded distribution. Do not label public
specifications proprietary data or federation a demonstrated network effect.

Initial decision targets (not achieved claims): ten independent builders, seven
unassisted activations, recurring external workflows, materially lower total
engineering effort than strong alternatives, and two organisations willing to
pay for operational deployment value. Preserve unsupported tasks and abstentions
in the denominator. Retain external holdouts; do not tune against final tests.

## Verification and release discipline

Run `python3 scripts/acceptance-experience.py` for the portable ledger component.
Run `swift test --force-resolved-versions` and the existing MCP/core/federation
acceptance on macOS. The new source is opt-in and does not change installations,
credentials, releases or Homebrew. No automatic merge or release is requested.

The initial tests were authored alongside implementation, not independently
preregistered. Record actual results separately; do not turn targets into claims.
