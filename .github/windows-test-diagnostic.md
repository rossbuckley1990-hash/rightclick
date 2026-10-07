# Windows test-start diagnostic scope

This branch adds only CI files on frozen39b (`39b37afbcc288eb07c5fe341b506f35ebb77e361`). It does not change product Sources, Tests, Vendor, fixtures, package inputs or tracked scripts. Independently packaging it produces the same source SHA256 `d2d42b8f24d9bfda18e7f2b2e36ee529db4a33c7bf763b8e83f3fca139974741`. A diagnostic run reports its own head; it must not be relabelled as a passing39b job.

The retained39b Windows run passes nine protected-reference tests and discovers666 distinct test names in667 log lines. Integrated tests hit the explicit25minute step deadline after a97.93second build. No retained launch/child/exit trace or test-case rows locate the wait. The cause remains unknown.

SwiftPM6.2 release source has a specific inner-buffering risk: its TestRunner uses streaming AsyncProcess, while Windows AsyncProcess readability callbacks read up to Int.max (lines483/497). The outer supervisor drains available bytes without waiting for newline or child completion; it cannot force bytes that this upstream layer has not emitted. This is source analysis, not a measured explanation of the39b timeout. Fixture setup/teardown also has unbounded process waits, but none is established as the cause.

The dedicated Windows-only push trigger matches `codex/windows-test-diagnostic-*`, which is outside the ordinary portable workflow's push branches. Its separate concurrency group does not cancel39b Mac/Linux work. Manual dispatch is not assumed: GitHub's default-main contents lookup for portable-runtime.yml returned404 even though its workflow registry entry is active. GitHub requires a default-branch dispatch definition. No dispatch or push was performed in preparing this change.

The diagnostic workflow preserves protected references, explicit full test build, discovery, full unfiltered `swift test --skip-build --force-resolved-versions`, release build and actual seven-operation provider acceptance. It checks all666 unique discovered XCTest names. Skip-build affects building, not test filtering; no filter/skip/library-disable option is supplied for the full run. Inner supervisor deadline24minutes is below the step's25minutes.

Windows startup creates the test command suspended, assigns it to a private kill-on-close Job Object, then resumes its sole initial thread. Job membership and open process handles determine ownership. Metadata retains only owned PIDs, executable basenames, creation times and CPU times; a queried PID must still belong to the same job. Root labels also compare creation identity. Neither command lines, arguments nor environment values are retained. Cleanup targets the job handle, never a PID from historical metadata. Assignment or native API failure fails closed as supervisor error125.

The supervisor writes launch, heartbeat, exit/timeout and cleanup records and a terminal phase. `--progress` flushes compact metadata to live stderr; it is off by default. Output draining uses raw reads on a separate thread, while the monitor continues independently. Normal child exit codes are retained; deadline exits124; supervisor failures exit125. Pipe drain and cleanup waits are bounded. Ordinary test output is retained as before; private fixture stderr files are never enumerated or copied.

Seven meaningful owned-process controls pass on macOS: newline-free early output, output exceeding pipe capacity on both streams, nonzero exit retention, silent deadline, descendant-held output handle, launch failure and metadata privacy. A separate actual progress/deadline control passes. The native Windows Job Object/descendant/outsider control remains RED until the workflow executes it; it runs first and must pass before suite gates. YAML parsing passes. No Windows success is claimed from macOS execution.

An optional follow-up can run the actual compiled XCTest PE directly under the same supervisor after full SwiftPM failure. Retained native build logs name `rightclick-mcpPackageTests.xctest` (do not assume .exe), and all666 discovered names are XCTest; current Tests contain no import Testing/@Test/@Suite. That supports a full XCTest diagnostic, but exact native runner path, DLL search environment, dump-tests inventory equality and absence of non-XCTest suites still require native verification. It would not replace the preserved SwiftPM/release/provider gates and is not included in this primary change.

Primary references:

- https://raw.githubusercontent.com/swiftlang/swift-package-manager/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift
- https://raw.githubusercontent.com/swiftlang/swift-package-manager/swift-6.2-RELEASE/Sources/Basics/Concurrency/AsyncProcess.swift
- https://raw.githubusercontent.com/swiftlang/swift-package-manager/swift-6.2-RELEASE/Sources/Commands/Utilities/TestingSupport.swift
- https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
- https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags
- https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow
