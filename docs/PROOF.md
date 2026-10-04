# RIGHTCLICK-004 proof

This file records only the completed acquisition experiment. It does not claim that every macOS context-menu item can be discovered or invoked.

The tested mechanism is a macOS Service declared with the documented `NSServices` Info.plist key, accepting `public.image`, and invoked with `NSPerformService`.

## Facts

- Baseline for `/Users/you/Desktop/test.jpg`: 11 capabilities.
- An independent app was installed at `~/Library/Services/RIGHTCLICK Test Provider.app`.
- Provider bundle ID: `dev.rightclick.test-provider`.
- New capability ID: `service:dev.rightclick.test-provider:createSidecar`.
- Title: `RIGHTCLICK Test — Create Sidecar`.
- RIGHTCLICK source does not name this provider or this action. Discovery used the generic Services scan.
- Local execution went through RIGHTCLICK. `NSPerformService("RIGHTCLICK Test — Create Sidecar")` returned true.
- Observable result: `/Users/you/Desktop/test.jpg.rightclick-test.txt` containing `RIGHTCLICK dynamic capability executed`.
- After the provider was removed and unregistered, discovery returned the same 11 capability IDs as the baseline.
- The completed remote test, reported after this run, showed Grok Bot listing the new capability through the remote MCP server and executing it once. This repository does not contain a Grok transcript.

## Evidence

- `evidence/rightclick-004/before.json`
- `evidence/rightclick-004/before.txt`
- `evidence/rightclick-004/after.json`
- `evidence/rightclick-004/after.txt`
- `evidence/rightclick-004/after-removal.json`
- `evidence/rightclick-004/run.txt`
- `evidence/rightclick-004/sidecar.txt`
- `evidence/rightclick-004/provider/`

## Commits

- Product snapshot before this proof note: `c2eaa64205c45fbafead128b20304062bd6541e2`
- Baseline evidence commit: `60344a1940c59366081e8df3f8031dd2de360e50`

## Limit

PASS applies to the Services mechanism above. It does not show that Finder Action extensions are invokable, or that every newly installed Mac app exposes a capability RIGHTCLICK can run.
