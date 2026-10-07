# RIGHTCLICK × PRIVACY INTENT PROOF

Date: 2026-10-05 ~13:41–13:42 BST
RIGHTCLICK: 0.1.0

User intent: remove unnecessary Mac extended metadata from a disposable JPEG before sharing, leaving the image intact.

Provider: GraphicConverter 12 (`com.lemkesoft.graphicconverter12`)
Capability: Remove Extended Attributes (Xattr) using GraphicConverter
Capability ID: `service:com.lemkesoft.graphicconverter12:serviceRemoveXATTR`
Why selected: Title/semantics match xattr/data-hygiene intent directly (not convert; not “Remove Metadata” alone).

Fixture: disposable copy of harmless JPEG with synthetic xattr for instrumentation only:
- Name: `com.rightclick.privacy-proof`
- Value: `RIGHTCLICK-PRIVACY-PROOF-48291`
Cleaning performed only via RIGHTCLICK-discovered capability (not `xattr -c` / `xattr -d`).

File: `/tmp/rightclick-privacy-intent-82406/RIGHTCLICK-PRIVACY-PROOF.jpg`
Type: JPEG (`public.jpeg`) · Dimensions: 32×32 · Bytes: 468

Synthetic xattr before: YES
Synthetic xattr after: NO

SHA-256 before: `2b33fef1fc6e1ebafab2b7bc69866a7f14d7cc75ce84ee3aeef48402b3c8325a`
SHA-256 after: `2b33fef1fc6e1ebafab2b7bc69866a7f14d7cc75ce84ee3aeef48402b3c8325a` (unchanged — pure xattr removal)

Image dimensions after: 32×32
Image readable after: YES (`file` → JPEG JFIF; `sips` format jpeg)

Payload: file URL pasteboard · Invocation: `rightclick run --json --yes` once → EXECUTED
(`NSPerformService == true` not treated as semantic success)

Provider-specific RIGHTCLICK code: NO
App-specific MCP: NO

SEMANTIC OUTCOME: **PASS**

Artifacts: `run.json`, `actions.json`, `after.jpg` (post-clean content-identical JPEG).
