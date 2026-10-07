# Evidence claim — dynamic capability-driven planning

This is the strongest causal proof so far.

You now have an **A → B → A' reversal**:

```text
A — ImageOptim installed
GraphicConverter → ImageOptim
Final JPEG: ~58 KB

B — ImageOptim removed
GraphicConverter only
Final JPEG: ~67 KB

A' — ImageOptim reinstalled
GraphicConverter → ImageOptim
Final JPEG: ~57 KB
```

And the user prompt stayed effectively the same.

That means the plan changed because the **environment changed**, not because you rewrote an integration or workflow.

## What this proves

The clean claim is:

> **RIGHTCLICK lets the agent build its strategy from the capabilities currently present on the machine. When software disappears, the plan adapts. When the software returns, the stronger plan returns automatically.**

That is materially different from static MCP wiring.

Traditional workflow:

```text
GraphicConverter MCP
      ↓
ImageOptim MCP
      ↓
hard-wired workflow
```

If ImageOptim disappears, the workflow breaks or needs reconfiguration.

What you just demonstrated is closer to:

```text
USER GOAL
   ↓
CURRENT ENVIRONMENT
   ↓
RIGHTCLICK capability graph
   ↓
AI synthesises best available plan
```

So:

```text
install app
→ capability appears
→ plan improves

remove app
→ capability disappears
→ plan degrades gracefully

reinstall app
→ capability reappears
→ plan improves again
```

No RIGHTCLICK code change.  
No new MCP.  
No workflow edit.

## Demo lead

Not “RIGHTCLICK found 59 tools.”

Show this:

> **Same AI. Same request. Same file.**
>
> With ImageOptim installed, the AI uses GraphicConverter + ImageOptim.
>
> Remove ImageOptim, ask again: it automatically falls back to GraphicConverter.
>
> Reinstall ImageOptim, ask again: it automatically discovers and uses ImageOptim again.
>
> **Nothing was integrated. The AI adapted to the software environment.**

## The deeper primitive

**Dynamic capability-driven planning** — or more simply: **environment-adaptive agents**.

RIGHTCLICK is no longer merely demonstrating “AI can discover tools.”

It is demonstrating: **“The AI’s plan is compiled from whatever capabilities exist right now.”**

## Proof stack (context)

- Dynamic acquisition — install apps → new capabilities appear
- Intent resolution — “run this” / “make image smaller” map to the right provider
- Capability composition — GraphicConverter → ImageOptim
- Dynamic substitution — remove ImageOptim → plan falls back
- Capability restoration — reinstall ImageOptim → richer plan returns
- Semantic verification — real files/results changed as expected
- Zero app-specific MCPs for these examples

## Next evidence that matters

Wild-environment reproduction on another Mac with apps we have never chosen or tested.

If another user gets the same pattern with unfamiliar software, then:

> **The software ecosystem itself expands the agent’s abilities and changes its plans without RIGHTCLICK engineers writing integrations.**
