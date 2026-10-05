# RIGHTCLICK v0.1 scalability / blind discovery evidence

Date: 2026-10-05 (Europe/London)
Machine: Apple Silicon (arm64), macOS 26.4.1 (Build 25E253)
RIGHTCLICK: 0.1.0 (`/opt/homebrew/bin/rightclick`)
Method: RIGHTCLICK CLI discovery (`inspect` / `actions` / `providers` / intentional `run`) plus one MCP meta-routing compress (`context_*`)
Constraints honored: no provider-specific RIGHTCLICK code; no app-specific MCP; no AppleScript / Accessibility / UI automation as substitute; ImageOptim excluded from PNG→JPEG intent (used for compress-intent).

## Test suite (this folder)

| Test | Result | Path |
|---|---|---|
| External-machine blind discovery (excluded known providers) | **FAIL** (0 new applicable third-party) | [`external-blind/`](external-blind/) |
| Capability scalability census (16 fixture types) | **DONE** — 59 unique caps, 39 providers | [`census/`](census/) |
| Four-app blind discovery (apps installed without naming) | **PASS discovery** — Acorn, Cyberduck, GraphicConverter 12 applicable; Keka providers-only | [`four-app-blind/`](four-app-blind/) |
| Image conversion intent (PNG→JPEG, AI chooses capability) | **SEMANTIC PASS** | [`png2jpeg-intent/`](png2jpeg-intent/) |
| Privacy / xattr hygiene intent (remove synthetic xattr, image intact) | **SEMANTIC PASS** | [`privacy-intent/`](privacy-intent/) |
| Compress intent (smaller JPEG, AI chooses capability; MCP meta-routing) | **SEMANTIC PASS** | [`compress-intent/`](compress-intent/) |
| Multi-app composition (PNG→JPEG via GC, then ImageOptim compress) | **COMPOSITION + SEMANTIC PASS** | [`composition-png-jpeg-optim/`](composition-png-jpeg-optim/) |
| Safety-aware planning (local prep + stop at external_share) | **PASS** (no unauthorized transfer) | [`safety-aware-planning-transfer/`](safety-aware-planning-transfer/) |
| Dynamic substitution / capability restoration (A→B→A' ImageOptim) | **DYNAMIC SUBSTITUTION + RESTORATION PASS** | [`dynamic-substitution/`](dynamic-substitution/) |
| Cross-domain CSV→chart (R → ImageOptim; intermediate rediscovery) | **CROSS-DOMAIN COMPOSITION + REDISCOVERY PASS** | [`cross-domain-csv-chart/`](cross-domain-csv-chart/) |

Related earlier v0.1 semantic / acquisition evidence (already in repo):
- `evidence/v0.1-coteditor/`
- `evidence/v0.1-homebrew/`
- `evidence/v0.1-final/`

## North-star claim these tests support

An AI can discover useful capabilities from ordinary installed Mac software via RIGHTCLICK reflection **without** being told the app name or a capability ID, and (for convert / privacy hygiene / compress / multi-app composition / dynamic substitution / cross-domain CSV→chart with intermediate-output rediscovery) produce an independently observed semantic outcome. Plans are compiled from the current capability graph: when software appears or disappears, or when one step creates a new object with a different graph, the plan adapts.

## What is *not* claimed

- `NSPerformService == true` alone is not semantic success (PNG→JPEG PASS required on-disk JPEG; Compress PASS required measured byte reduction with intact JPEG).
- Keka appeared in `providers` but matched **0** `actions` on the fixture corpus — providers ≠ usable capability.
- Cyberduck Upload was discovered but **not executed** (`safety=external_share`).

## v0.1 scalability / blind suite (2026-10-05)

See [`v0.1-scalability-blind/`](v0.1-scalability-blind/).
