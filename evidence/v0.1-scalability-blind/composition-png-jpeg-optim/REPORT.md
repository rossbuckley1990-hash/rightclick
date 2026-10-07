# Multi-app composition — PNG → JPEG → ImageOptim — PASS

Date: 2026-10-05 (Europe/London)
RIGHTCLICK: 0.1.0
Method: MCP `context_actions` / `context_run` / `context_inspect` (composition of two unrelated providers)

## User intent

Prepare a disposable PNG for web sharing: convert to JPEG at good visual quality; preserve pixel dimensions; make the JPEG as small as reasonably possible without visible degrade; keep local; preserve the original PNG. Compose multiple discovered capabilities if one app cannot do the whole job.

## Constraints

- Transformations only via discovered RIGHTCLICK capabilities
- No shell/Python/AppleScript/Accessibility/Computer Use/app-specific MCPs for the transforms
- Shell used only for fixture creation and independent verify
- Each capability executed at most once
- `NSPerformService == true` alone ≠ semantic success

## Step 1 — GraphicConverter 12

- Capability: Convert to JPEG (Quality 85%) — `service:com.lemkesoft.graphicconverter12:serviceConvertJPEG85`
- executionId: `16203C70-D049-4889-B61C-0DBA5B6DAE5D`
- Result: new JPEG beside source; PNG untouched

## Step 2 — ImageOptim

- Capability: ImageOptimize — `service:net.pornel.ImageOptim:handleServices`
- executionId: `5FD1FE94-4CFF-4BC8-8253-37C7667B489A`
- Result: in-place JPEG shrink; dimensions unchanged

## Independent verify

| Check | Result |
|---|---|
| Original PNG preserved | YES — SHA-256 `fb5afc8b1822573f2bf32b501b0338b9ca99058850a65f38cdc83560f065e8d4` (`196992` bytes) |
| Intermediate JPEG | `68846` bytes — SHA `0fcd1f3349f2899b8f3840f31df8ba0fe8fd299a392369e8fd0dff0498d1b430` |
| Final JPEG | `58209` bytes — SHA `428c8bb42efa5cb77e0517648880c8edc9d45948a4f66b74f940210fa6c327ca` |
| Dimensions | 256×256 before and after |
| Final format | JPEG, readable |
| App-specific MCPs | NO |
| Provider-specific RIGHTCLICK code | NO |

## Verdict

- **CAPABILITY COMPOSITION: PASS** (two distinct providers in sequence)
- **SEMANTIC OUTCOME: PASS**

## Artifacts

- [`source.png`](source.png)
- [`intermediate.jpg`](intermediate.jpg) — post-convert, pre-ImageOptim
- [`after.jpg`](after.jpg) — final
- [`run-step1.json`](run-step1.json), [`run-step2.json`](run-step2.json)
