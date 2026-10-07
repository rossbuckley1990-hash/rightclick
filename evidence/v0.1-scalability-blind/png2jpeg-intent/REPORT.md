# RIGHTCLICK × IMAGE CONVERSION INTENT PROOF

Date: 2026-10-05 ~13:34–13:35 BST

Provider: GraphicConverter 12 (`com.lemkesoft.graphicconverter12`)
Capability: Convert to JPEG (Quality 85%) using GraphicConverter
Capability ID: `service:com.lemkesoft.graphicconverter12:serviceConvertJPEG85`
Why selected: Discovered on disposable PNG via `actions --json` (ImageOptim excluded). Local IMAGE_CONVERT at reasonable quality; not upload/share.

Source path: `/tmp/rightclick-png2jpeg-intent-81412/RIGHTCLICK-PNG2JPEG-SOURCE.png`
Source type: PNG (`public.png`)
Source dimensions: 1×1
Source bytes: 69
Dir before: only that PNG

Payload: file URL on pasteboard (`NSPasteboardTypeFileURL` / `public.file-url`)
Invocation: `rightclick run --json --yes` once → status `EXECUTED`
(NSPerformService returned true — **not** alone treated as semantic success)

Source file: **unchanged** (69 bytes, SHA-256 `c47dd9465c00e9a0c8b85e9ea58d3034a0d23b9cf926113602f3460752a4eb96`)
Output path: `/tmp/rightclick-png2jpeg-intent-81412/RIGHTCLICK-PNG2JPEG-SOURCE.jpg` (artifact: `output.jpg`)
Output type: JPEG (`public.jpeg`)
Output dimensions: 1×1
Output bytes: 2979
JPEG readable: **YES** (`file` → JPEG JFIF; `sips` format jpeg; RIGHTCLICK inspect)

Provider-specific RIGHTCLICK code: NO
App-specific MCP: NO

SEMANTIC OUTCOME: **PASS**
