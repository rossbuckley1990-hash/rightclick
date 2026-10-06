# RIGHTCLICK × COMPRESS INTENT / META-ROUTING PROOF

Date: 2026-10-05 ~14:46–14:52 BST
RIGHTCLICK: 0.1.0 (MCP connector `user-RIGHTCLICK`)
Client: Grok Bot (agent routing via discovered Services — not CLI)

User intent: make a disposable JPEG smaller without changing dimensions or visibly degrading it. Prefer an existing installed application capability. If none suitable, stop rather than shell / AppleScript / Accessibility / Computer Use.

Provider: ImageOptim (`net.pornel.ImageOptim`)
Capability: ImageOptimize
Capability ID: `service:net.pornel.ImageOptim:handleServices`
Why selected: Discovered via MCP `context_actions` on the JPEG. Title/semantics match lossless-leaning recompress / size reduction without resize. GraphicConverter “Convert to JPEG (Quality N%)” would re-encode at a fixed quality and was a weaker match for “smaller without visibly degrading.” Action-extension ImageOptimize is `unsupported` for invocation.

Alternatives considered and not used: GraphicConverter quality convert; shell `jpegoptim`/`sips`/ImageMagick; direct app launch; AppleScript; Accessibility; Computer Use.

File: `/tmp/RIGHTCLICK-META-ROUTING-FINAL-68311.jpg`
Type: JPEG (`public.jpeg`)

Bytes before (MCP `context_inspect`): 676
Bytes after (MCP `context_inspect` + on-disk): 468 (~31% smaller)
Dimensions after (`sips`): 32×32
Format after: jpeg / JFIF readable (`file`, `sips`)
SHA-256 after: `2b33fef1fc6e1ebafab2b7bc69866a7f14d7cc75ce84ee3aeef48402b3c8325a`

Pixel dimensions before were not exposed by MCP `context_inspect`. ImageOptim recompresses in place and does not change pixel dimensions; post-run size drop with unchanged 32×32 JPEG is the independent observation.

Invocation: MCP `context_run` with `confirmed=true` once → `state: succeeded`
executionId: `0D6BCB6F-73EB-4111-8B9B-73B2DF7B257D`
(`NSPerformService == true` accepted the Service; semantic success required the measured byte reduction and intact JPEG.)

Provider-specific RIGHTCLICK code: NO
App-specific MCP: NO
Shell / AppleScript / Accessibility / Computer Use for the compress step: NO

SEMANTIC OUTCOME: **PASS** (size reduced; still JPEG; dimensions 32×32 after)

Meta-routing note: An ordinary AI client chose ImageOptim from the reflected catalog for a compress intent and invoked it only through RIGHTCLICK, under an explicit ban on fallback automation.

Artifacts: `run.json`, `actions.json`, `inspect-before.json`, `inspect-after.json`, `after.jpg`.
