# Exact-source concurrent PR reconciliation

Reviewed PR45 `d8d6f585a0b890b749c892641aa43fbd52ad4a6a`, PR46 `cd19b2cc7f28e1424559be9e5088f94b35a73b26`, and PR47 `57b5d87cc54c26c2b444fb232bb2ffa8e49b34c3` against base `c2f3bac98ade0d5f87aeb079d4c2274c55ece561`. This was read-only engineering review: no merges, root edits, credentials, effect calls, or new infrastructure.

PR45 shares `CapabilityArtifactResolver.swift` and `ConfiguredOpenAPISource.swift` with PR47. Its artifact cache rewrite removes the old cache-check block containing PR47's immediate stale-contract bypass. Preserve both conditions under PR45's serialized reload lock:

```swift
let requiresContractRefresh = cachedReflectors.contains {
    ($0 as? any CapabilityContractRefreshingReflector)?.requiresContractRefresh == true
}
if !requiresContractRefresh && freshness.isFresh(at: clock()) {
    return cachedReflectors
}
```

This is an integration instruction, not an implemented or tested patch. Preserve PR47's configured revalidation loader and immediate stale compiler reacquisition/object-identity replacement while integrating bounded configured reloads and source invalidation. Keep current-contract admission checks before consumption and after dispatch. Cache freshness never grants execution authority. Rerun unchanged production controls, public freshness proof, native regressions and PR45 lifecycle tests on the combined exact head; add a still-fresh cache plus known-stale-contract regression. PR45's existing green checks do not establish combined behavior.

PR45 improves G5 discovery lifecycle and supports later graph acceptance; it adds no substrate acquisition. It is not an identified missing G2 prerequisite for the pinned PR47 production path.

PR46 has no overlapping production sources. Existing exact-head CI run `37626548671` actually passed Linux/Kafka/Kubernetes and native Windows readiness. Downloaded artifacts retain actual target effects, independent observations, scoped-identity denial and teardown. Kubernetes TokenRequest plus API can supply a real disposable issuer/provider pair for later G3. This does not establish RIGHTCLICK broker/observer/signer integration, portable runtime products, any seven-operation substrate row, or the eleven-substrate proof. Respect the artifacts' explicit infrastructure-only scope. Both PRs remain other-owner work; preserve and review before any integration.

Full identities, scope distinctions and evidence hashes are in `reconciliation.json` and `SHA256SUMS.json`. Relevant source/test diffs and the downloaded existing CI evidence are retained alongside them.
