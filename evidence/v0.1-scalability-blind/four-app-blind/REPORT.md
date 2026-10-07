# RIGHTCLICK FOUR-APP BLIND DISCOVERY

Date: 2026-10-05 ~13:30–13:33 BST
Fixtures: `/tmp/rightclick-four-app-blind-C4kL/` (copies of micro-fixtures under `fixtures/` here)
RIGHTCLICK: 0.1.0
Previously known providers excluded: YES

New vs prior providers list: **Acorn**, **Cyberduck**, **GraphicConverter 12**, **Keka**

New applicable third-party providers: **3** (Acorn, Cyberduck, GraphicConverter 12)

## NEW CAPABILITIES (actions --json only)

### Acorn (`com.flyingmeat.Acorn8`)
- Open Image in Acorn — `service:com.flyingmeat.Acorn8:openImageFromService` — OPEN — interactive — safety unknown — JPEG, PNG

### Cyberduck (`ch.sudo.cyberduck`)
- Upload with Cyberduck — `service:ch.sudo.cyberduck:serviceUploadFileUrl` — UPLOAD — interactive — **external_share** — many file-like fixtures
- **Not executed** (external upload risk)

### GraphicConverter 12 (`com.lemkesoft.graphicconverter12`)
- Convert to JPEG (Quality 75%) — `service:…:serviceConvertJPEG75` — IMAGE_CONVERT — JPEG, PNG
- Convert to JPEG (Quality 85%) — `service:…:serviceConvertJPEG85` — IMAGE_CONVERT — JPEG, PNG
- Create Icon and Preview — `service:…:serviceCreateIconPreview` — IMAGE_EDIT
- Open using GraphicConverter — `service:…:serviceOpenInGraphicConverter` — OPEN
- Remove Extended Attributes — `service:…:serviceRemoveXATTR`
- Remove Metadata — `service:…:serviceRemoveMetadata`
- Remove Resourcefork — `service:…:serviceRemoveResourcefork`
- Rename… — `service:…:serviceRename` — OTHER
- Rotate JPEG lossless depending on Exif — `service:…:serviceRotateFileToExif`
- Set File Date to Exif Date — `service:…:serviceSetFileDateToExifDate`
- Set default XMP — `service:…:serviceSetXMPIPTC`
- Show in Browser — `service:…:serviceShowInGraphicConverterBrowser`
- Show random / sorted in Slide Show — slideshow services

## PROVIDERS INSTALLED BUT WITH NO APPLICABLE CAPABILITY
- **Keka** (`com.aone.keka`) — present in `providers --json` (Compress/Extract/Send to Keka); **zero** `actions` matches across fixtures

## STRONGEST SAFE CANDIDATE (not executed in this phase)
`service:com.lemkesoft.graphicconverter12:serviceConvertJPEG75` (later intent proof used 85%)

Multi-file: CLI accepted extra paths but only first item used — not a distinct object type.
