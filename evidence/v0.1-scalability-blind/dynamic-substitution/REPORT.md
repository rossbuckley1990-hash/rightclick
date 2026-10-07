# Dynamic substitution (A → B → A') — PASS

Date: 2026-10-05 (Europe/London)
RIGHTCLICK: 0.1.0
Method: MCP `context_actions` / `context_run` / `context_inspect`
Agent: New Bot (Grok Bot family), same user goal across phases

## Claim

RIGHTCLICK lets the agent build its strategy from the capabilities currently present on the machine. When software disappears, the plan adapts. When the software returns, the stronger plan returns automatically — with no RIGHTCLICK code change, no new MCP, and no workflow edit.

## User intent (held constant)

Prepare a disposable PNG for web sharing: convert to a regular JPEG at good visual quality; preserve pixel dimensions; make the JPEG as small as reasonably possible without visible degrade; keep everything local; preserve the original PNG; verify the result.

Prompt stayed effectively the same across A / B / A'.

## Environment reversals

| Phase | ImageOptim | Observed plan | Final JPEG |
|---|---|---|---|
| **A** (prior composition run) | installed | GraphicConverter → ImageOptim | ~58 KB (`58209`) |
| **B** (`…-SUBSTITUTION-B`) | removed / unavailable in action set used | GraphicConverter only (JPEG 85%) | ~67 KB (`68846`) |
| **A'** (`…-SUBSTITUTION-C`) | reinstalled | GraphicConverter → ImageOptim | ~57 KB (`58209`) |

## Phase B — GraphicConverter only

- Input: `/tmp/RIGHTCLICK-DYNAMIC-SUBSTITUTION-B.png` (256×256 PNG, `196992` bytes)
- Capability: Convert to JPEG (Quality 85%) — `service:com.lemkesoft.graphicconverter12:serviceConvertJPEG85`
- executionId: `EB505A46-83EF-4A1A-ADEC-2E4D295C3780`
- Output: `/tmp/RIGHTCLICK-DYNAMIC-SUBSTITUTION-B.jpg` — `68846` bytes, 256×256 JPEG
- SHA-256 JPEG: `0fcd1f3349f2899b8f3840f31df8ba0fe8fd299a392369e8fd0dff0498d1b430`
- PNG preserved: SHA-256 `fb5afc8b1822573f2bf32b501b0338b9ca99058850a65f38cdc83560f065e8d4`

## Phase A' — GraphicConverter → ImageOptim

- Input: `/tmp/RIGHTCLICK-DYNAMIC-SUBSTITUTION-C.png` (same PNG bytes as B source)
- Step 1: Convert to JPEG (Quality 85%) — `service:com.lemkesoft.graphicconverter12:serviceConvertJPEG85`
  - executionId: `680FBA62-03BF-410D-8624-4EB94B74F00F`
- Step 2: ImageOptimize — `service:net.pornel.ImageOptim:handleServices`
  - executionId: `D7CF66C1-1619-4E34-8FE8-F7501459D2C2`
- Output: `/tmp/RIGHTCLICK-DYNAMIC-SUBSTITUTION-C.jpg` — `58209` bytes, 256×256 progressive JPEG
- SHA-256 JPEG: `428c8bb42efa5cb77e0517648880c8edc9d45948a4f66b74f940210fa6c327ca`
- PNG preserved: same SHA-256 as B source

## Independent verify

| Check | Result |
|---|---|
| Same user goal across phases | YES |
| Plan changed with environment | YES — ImageOptim step present only when discovered |
| B final larger than A/A' | YES — `68846` vs `58209` |
| Dimensions preserved | YES — 256×256 |
| Original PNGs preserved | YES |
| App-specific MCPs | NO |
| Provider-specific RIGHTCLICK code | NO |
| RIGHTCLICK / workflow edit between phases | NO |

## Verdict

- **DYNAMIC SUBSTITUTION: PASS** (remove capability → plan degrades gracefully)
- **CAPABILITY RESTORATION: PASS** (reinstall → richer plan returns)
- **SEMANTIC OUTCOME: PASS** (on-disk JPEG sizes and formats match the plans)

## Product framing

Same AI. Same request. Same file family.

With ImageOptim installed → GraphicConverter + ImageOptim.  
Remove ImageOptim → falls back to GraphicConverter.  
Reinstall ImageOptim → discovers and uses ImageOptim again.

Nothing was integrated. The AI adapted to the software environment.

Primitive name: **dynamic capability-driven planning** / **environment-adaptive agents**.

## Artifacts

- [`phase-B-source.png`](phase-B-source.png) — copy of composition `source.png` (identical SHA)
- [`phase-B-gc-only.jpg`](phase-B-gc-only.jpg) — copy of composition `intermediate.jpg` (identical SHA; B final)
- [`phase-A-source.png`](phase-A-source.png) — same PNG bytes
- [`phase-A-gc-imageoptim.jpg`](phase-A-gc-imageoptim.jpg) — copy of composition `after.jpg` (identical SHA; A' final)
- [`CLAIM.md`](CLAIM.md) — narrative claim for demos / product story

Byte-identical with `evidence/v0.1-scalability-blind/composition-png-jpeg-optim/` image SHAs recorded in that REPORT.
