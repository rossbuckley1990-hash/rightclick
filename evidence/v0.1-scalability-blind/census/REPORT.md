# RIGHTCLICK CAPABILITY SCALABILITY CENSUS

Generated: 2026-10-05T13:20:05 BST (Europe/London)  
RIGHTCLICK: 0.1.0 @ `/opt/homebrew/bin/rightclick`  
Fixtures: `/tmp/rightclick-census-78231`  
Method: `rightclick actions --json` only (no capability execution, no installs, no RIGHTCLICK modification).

## Headline counts
- Object types tested: **16**
- Unique capabilities: **59**
- Unique providers (from actions): **39**
- Third-party providers: **10** (7 known observed + 3 Claude registered)
- Previously unseen third-party providers: **3**
- Invocable capabilities: **5**
- Discovery-only capabilities: **54**
- Semantic classes represented: ANALYSE, COMPUTE, CONVERT, CREATE, EDIT, MEDIA, OPEN, OPTIMISE, SEARCH, SHARE, TRANSFORM, UNKNOWN

## Per-fixture action counts
| Fixture | N |
|---|---:|
| text | 45 |
| url | 51 |
| txt | 47 |
| md | 47 |
| json | 45 |
| csv | 47 |
| pdf | 6 |
| jpg | 12 |
| png | 12 |
| svg | 12 |
| mp3 | 6 |
| wav | 6 |
| mp4 | 8 |
| zip | 5 |
| code | 47 |
| folder | 7 |

## OBJECT TYPE COVERAGE (unique capability IDs)
- text: 45
- URL: 51
- image: 12
- PDF: 6
- audio: 6
- video: 8
- archive: 5
- folder: 7
- code: 47

## SEGMENT COUNTS
- Apple/system unique caps: 45
- Known third-party unique caps: 14
- Unseen third-party unique caps (from actions): 0

## THIRD-PARTY CAPABILITY GRAPH
### BBEdit/Append Selection to BBEdit Scratchpad
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/Append Selection to BBEdit Scratchpad
- ID: `service:com.barebones.bbedit:appendToScratchpadService`
- Class: EDIT
- Inputs: ['NSStringPboardType', 'public.utf8-plain-text']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### BBEdit/Compare Using BBEdit
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/Compare Using BBEdit
- ID: `service:com.barebones.bbedit:compareFilesService`
- Class: SEARCH
- Inputs: ['NSURLPboardType', 'public.file-url']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: url

### BBEdit/New BBEdit Document with Selection
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/New BBEdit Document with Selection
- ID: `service:com.barebones.bbedit:openSelectionService`
- Class: CREATE
- Inputs: ['NSStringPboardType', 'public.plain-text']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### BBEdit/New Note in BBEdit
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/New Note in BBEdit
- ID: `service:com.barebones.bbedit:newNoteWithSelectionService`
- Class: CREATE
- Inputs: ['NSStringPboardType', 'public.plain-text', 'public.utf8-plain-text']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### BBEdit/Open File in BBEdit
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/Open File in BBEdit
- ID: `service:com.barebones.bbedit:openFileService`
- Class: OPEN
- Inputs: ['NSStringPboardType', 'public.utf8-plain-text', 'NSURLPboardType', 'public.url', 'public.file-url']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### BBEdit/Search Here in BBEdit
- Provider: BBEdit
- Bundle: com.barebones.bbedit
- Capability: BBEdit/Search Here in BBEdit
- ID: `service:com.barebones.bbedit:multiFileSearchService`
- Class: SEARCH
- Inputs: ['NSStringPboardType', 'public.utf8-plain-text', 'NSURLPboardType', 'public.url', 'public.file-url']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### New CotEditor Window Containing Selection
- Provider: CotEditor
- Bundle: com.coteditor.CotEditor
- Capability: New CotEditor Window Containing Selection
- ID: `service:com.coteditor.CotEditor:openSelection`
- Class: CREATE
- Inputs: ['NSStringPboardType']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### Open in CotEditor
- Provider: CotEditor
- Bundle: com.coteditor.CotEditor
- Capability: Open in CotEditor
- ID: `service:com.coteditor.CotEditor:openFile`
- Class: OPEN
- Inputs: ['NSURLPboardType', 'NSStringPboardType']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### ImageOptimize
- Provider: ImageOptim
- Bundle: net.pornel.ImageOptim
- Capability: ImageOptimize
- ID: `service:net.pornel.ImageOptim:handleServices`
- Class: OPTIMISE
- Inputs: ['public.png', 'public.jpeg', 'com.compuserve.gif', 'public.svg-image']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: jpg, png, svg

### ImageOptimize
- Provider: ImageOptimize
- Bundle: net.pornel.ImageOptimizeExtension
- Capability: ImageOptimize
- ID: `action:net.pornel.ImageOptimizeExtension`
- Class: OPTIMISE
- Inputs: ['public.jpeg']
- Source: action_extension
- Invocable: no (invocation=unsupported, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: jpg, png, svg

### Open in ZCode
- Provider: Open in ZCode
- Bundle: dev.zcode.app.finder-open-workflow
- Capability: Open in ZCode
- ID: `service:dev.zcode.app.finder-open-workflow:runWorkflowAsService`
- Class: OPEN
- Inputs: ['public.folder', 'public.directory']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: folder

### R/R – Open selection
- Provider: R
- Bundle: org.R-project.R
- Capability: R/R – Open selection
- ID: `service:org.R-project.R:doPerformServiceOpenRScript`
- Class: OPEN
- Inputs: ['NSStringPboardType']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### R/R – Run selection in Console
- Provider: R
- Bundle: org.R-project.R
- Capability: R/R – Run selection in Console
- ID: `service:org.R-project.R:doPerformServiceRunInConsole`
- Class: COMPUTE
- Inputs: ['NSStringPboardType', 'NSURLPboardType']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

### Open in Yojam
- Provider: Yojam
- Bundle: com.yojam.app
- Capability: Open in Yojam
- ID: `service:com.yojam.app:openURLViaService`
- Class: OPEN
- Inputs: ['public.url', 'public.rtf', 'public.utf8-plain-text', 'NSStringPboardType', 'public.plain-text']
- Source: service
- Invocable: no (invocation=interactive, supportLevel=public_supported)
- safety: unknown; requiresConfirmation: True
- Observed on: text, url, txt, md, json, csv, code

## LONG-TAIL DISCOVERIES
No previously unseen third-party **capability IDs** were returned by `actions` on the corpus.
Registered previously unseen third-party **providers** (local Automator / Claude; not in known-tested list):
- `/Users/ross/Library/Services/Claude - ask.workflow` — titles=['Ask Claude']; source=service; bundle=null; **0 actions** on any census fixture
- `/Users/ross/Library/Services/Claude - codeHere.workflow` — titles=['New Claude Code Session Here']; source=service; bundle=null; **0 actions** on any census fixture
- `/Users/ross/Library/Services/Claude - send.workflow` — titles=['Send to Claude']; source=service; bundle=null; **0 actions** on any census fixture

## CURRENT CAPABILITY ENVELOPE
Across 16 synthetic object fixtures, rightclick actions --json surfaced 59 unique capability IDs from 39 providers (plus 3 Claude Automator workflows visible only via providers --json). Coverage is text/URL-heavy (45–51 caps) and code-adjacent (47); images 12; video 8; folder 7; PDF/audio 6; archive 5. Apple/system dominates (45 caps). Known third-party adds 14 caps (BBEdit, CotEditor, R, Yojam, ImageOptim/ImageOptimize, ZCode). Only 5 caps are direct-invocable (Chinese text converters + Script Editor AppleScript); 54 are interactive or unsupported discovery-only. No capability execution was performed.

## SCALABILITY BOTTLENECKS OBSERVED
- Invocation skew: 52 interactive + 2 unsupported vs 5 direct — nearly all census caps are discovery-only for automated run.
- Type skew: text/URL/code-rich; PDF/audio/archive/folder thin — binary and container objects expose few services.
- Third-party surface is mostly OPEN/CREATE/EDIT/SEARCH on text-like inputs; little third-party compute/transform on media besides ImageOptim.
- Claude local Automator workflows appear in providers --json but matched 0 actions for all 16 fixtures (eligibility/input-type gap).
- Duplicate ImageOptimize paths (service net.pornel.ImageOptim + action_extension net.pornel.ImageOptimizeExtension) both discovery-only here.
- Many share targets lack bundleIdentifier (name-only), complicating provider segmentation.
- supportLevel almost always public_supported even when invocation is interactive — supportLevel alone does not imply automatable invocation.

## Notes
- Claude Automator workflows appear in `rightclick providers --json` but returned zero matching actions for any census fixture via `rightclick actions --json`.
- Invocable = invocation in {direct, service, cli, automation, script}; interactive and unsupported counted as discovery-only.
- Classification from title/provider name keywords only.
