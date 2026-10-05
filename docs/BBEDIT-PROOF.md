# BBEdit proof

This is the public record of RIGHTCLICK-008. BBEdit 16.0.3 was installed independently after a frozen baseline. RIGHTCLICK's source was not edited to recognise BBEdit.

```text
BBEdit absent
36 text capabilities
0 third-party

BBEdit installed independently

RIGHTCLICK unchanged

41 text capabilities
5 BBEdit capabilities

generic execution:
PASS

semantic result:
PASS
```

The query both times was the plain text `RightClick third party capability test`.

The five capabilities that appeared, with the ids the release binary returned:

- New BBEdit Document with Selection — `service:com.barebones.bbedit:openSelectionService`
- New Note in BBEdit — `service:com.barebones.bbedit:newNoteWithSelectionService`
- Open File in BBEdit — `service:com.barebones.bbedit:openFileService`
- Search Here in BBEdit — `service:com.barebones.bbedit:multiFileSearchService`
- Append Selection to BBEdit Scratchpad — `service:com.barebones.bbedit:appendToScratchpadService`

BBEdit's Info.plist also declares Compare Using BBEdit. That service sends file URLs, so it did not apply to this text query.

```text
BBEdit-specific RIGHTCLICK code:
NONE
```

BBEdit is not an MCP server. It was not built for RIGHTCLICK. The titles, messages, and send types came from the documented `NSServices` key.

## Semantic execution

A later local run discovered `service:com.barebones.bbedit:openSelectionService` and invoked it once through RIGHTCLICK with:

```text
RIGHTCLICK generic service final proof 73194
```

`NSPerformService` returned true. BBEdit's rescued document contained that exact string and no extra bytes.

An earlier programmatic attempt opened BBEdit and left an empty document. The manual macOS Services menu, from TextEdit, already transferred a selected string correctly. A minimal AppKit harness outside RIGHTCLICK also transferred text when it kept the pasteboard alive after `NSPerformService` returned.

## Lifecycle

Some NSServices providers consume their pasteboard asynchronously after `NSPerformService` returns.

RIGHTCLICK generically retains the pasteboard and an AppKit run loop for 10 seconds when the service accepts the call and does not write a synchronous pasteboard result. It then releases the pasteboard.

No BBEdit-specific execution path exists. The same retention rule applies to any service that behaves this way. Services that write a result before returning, such as Convert Text to Full Width, are unchanged.

## v0.1 regression — 2026-10-05

The reconstructed candidate discovered the same Service, invoked it once through RIGHTCLICK, retained its pasteboard for 10 seconds after an accepted invocation, and created a new BBEdit window containing exactly `RIGHTCLICK v0.1 BBEdit regression 20261005` (42 characters). The initial selected window contained an older fixture; inspecting the Window menu exposed the newly created second document. The independent native text-area observation, rather than echoed command output, establishes semantic PASS. Raw discovery, invocation, diagnostics, and outcome are in `evidence/v0.1-final/bbedit-*`. No provider-specific production repair was added.

The earlier installed Homebrew candidate (SHA256 `78a2b82d4924b775a75e243a2e3a3f811b2c96414d5bd0e96d471f05a81c7db1`) was subsequently regressed once after release-only changes. BBEdit's new `untitled text 3` text area exactly contained `RIGHTCLICK v0.1 installed BBEdit proof 20261005`. Raw invocation and independent outcome are in `evidence/v0.1-final/installed-final/bbedit-*`.

## Public v0.1.0 bottle acceptance

After the exact public `brew install rossbuckley1990-hash/tap/rightclick`, the installed bottle binary (SHA256 `153d198a1971b8c4181a1ba1fc4efa32947d86b0ebf6a70493e17802cce240b2`) invoked the same discovered Service once. BBEdit created `untitled text 5` containing exactly `RIGHTCLICK v0.1 public bottle proof 20261005`. Independent native text-area and Text Statistics observations verified 44 characters, one line. This is semantic PASS, distinct from the accepted invocation and echoed payload. Raw final evidence is in `evidence/v0.1-homebrew/final-installed/bbedit-*`. No provider-specific production code was added.
