# Demo

The demo is RIGHTCLICK-004. It uses one JPEG and one independently installed macOS Service.

### Scene 1

```bash
rightclick actions /Users/ross/Desktop/test.jpg
```

11 capabilities. Markup, Set Desktop Picture, Add to Photos, AirDrop, and the other share services that macOS returned for that file. No test provider.

### Scene 2

Install `RIGHTCLICK Test Provider` (`dev.rightclick.test-provider`) as a normal Service that accepts `public.image`. Register it with `LSRegisterURL` and `NSUpdateDynamicServices`. Do not edit RIGHTCLICK.

### Scene 3

Run the same command.

12 capabilities. The new row is `RIGHTCLICK Test — Create Sidecar`, id `service:dev.rightclick.test-provider:createSidecar`.

### Scene 4

Ask the remote Grok Bot what the Mac can do with `test.jpg`.

Grok sees the new capability through the same MCP server.

### Scene 5

Ask Grok to execute `RIGHTCLICK Test — Create Sidecar` once.

`NSPerformService` returns true. `test.jpg.rightclick-test.txt` contains `RIGHTCLICK dynamic capability executed`.

### Scene 6

Remove the provider and query again.

The list returns to the original 11 capability IDs.

Evidence: `evidence/rightclick-004/` and `docs/PROOF.md`.
