# Portable delivery and acceptance gate

This is a source-candidate pipeline, not an assertion that every platform is already supported or that a tagged release has shipped. Read the exact commit's workflow results and validation.json. The installed Homebrew release is not changed by a feature-branch build.

## What is enforced

The same shared engine and seven MCP operations run on each host. macOS runs the full native suite. Linux runs every selected portable suite, without substituting macOS APIs. Windows runs native host-boundary tests and the real stdio/provider acceptance; HTTP-server and gRPC support remain disabled on Windows. Platform-specific desktop services are not invented on headless machines.

A build job must pass packaging rejection tests, the pinned SDK integrity check, native tests, a release build, three complete real acceptance runs, bundle integrity verification and a relocated clean-PATH run before its validation.json can say PASS. Failed jobs still upload diagnostic logs and partial reports. The separate clean Linux job installs OS prerequisites only and proves the packaged executable works without a Swift compiler or preinstalled Swift runtime.

Each candidate ZIP is named with its version, OS, architecture and source commit. It includes SHA-256 checksums for every member, the exact binary's acceptance report, required Swift runtime libraries on Linux/Windows, and retained project/dependency/runtime licences. Existing output archives and extraction destinations are never overwritten. Checksums prove byte integrity, not publisher authenticity, notarization or signing.

## Inspect a candidate

Obtain the complete artifact from the exact successful GitHub Actions run. Match the sourceSHA in validation.json and manifest.json. Do not mix archives or checksums from different commits. The verification tool uses only Python's standard library.

```sh
python3 scripts/portable-delivery.py verify RIGHTCLICK-CANDIDATE.zip \
  --sha256 EXPECTED_SHA256 --destination ./rightclick-candidate
./rightclick-candidate/bin/rightclick platform --json
./rightclick-candidate/bin/rightclick connect
```

On Windows use `python`, `rightclick.exe`, and PowerShell paths. Keep the extracted directory together: the Linux executable uses its sibling lib directory; Windows DLLs remain beside the executable. Linux requires compatible glibc and OS curl/XML/SSL libraries. Windows may require the Microsoft Visual C++ redistributable. macOS retains its native OS requirements. `connect` prints MCP client JSON and never silently edits another application's settings.

To build and validate from source with Swift 6.2.1 and Python installed:

```sh
python3 scripts/portable-delivery.py ci --output dist/portable
```

## Measurements, not multipliers

measurements.json records three independent acceptance subprocess runs, exact source/binary hashes, the native host, pass/failure counts, and median/p95 observer time to the first verified returned-text postcondition. Python output is unbuffered so milestones are observed when emitted. Timing includes fixture setup and safety checks; it is not human onboarding time, provider-independent latency, an external side-effect attestation, or a baseline speed-up comparison. Small-sample p95 is descriptive only. No 100-fold improvement is claimed.

## Release boundary

Do not publish a release until all platform jobs, relocated-bundle tests and the clean Linux job pass for one immutable source commit, integration with current main is reviewed, and bottle alignment is checked. Use a new version/tag for a release; never retag or replace an existing Homebrew artifact. Feature-branch candidates must remain labelled as candidates. Source-package construction retains Vendor/swift-sdk and its original licence. Any published platform support must be no broader than its native acceptance evidence.
