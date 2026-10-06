# Evidence claim — cross-domain composition + intermediate-output rediscovery

This is a major proof because it crosses capability domains and the output of one capability becomes the input to another.

You gave the agent a goal, not a workflow:

> Turn this sales data into a clear, web-ready chart.

The agent effectively constructed:

```text
CSV
 ↓
RIGHTCLICK discovers R
 ↓
R computes + renders
 ↓
new object appears: PNG
 ↓
RIGHTCLICK re-evaluates the new object
 ↓
discovers ImageOptim
 ↓
ImageOptim optimises it
 ↓
verified web-ready chart
```

That is different from merely calling two tools in sequence.

## What we have now proven

```text
User authored workflow:                 NO
User named R:                           NO
User named ImageOptim:                  NO
R-specific MCP:                         NO
ImageOptim-specific MCP:                NO
Provider-specific RIGHTCLICK code:      NO

Intent decomposition:                   PASS
Capability discovery:                   PASS
Cross-domain selection:                 PASS
Capability composition:                 PASS
Intermediate-output rediscovery:        PASS
Semantic execution:                     PASS
Final outcome verification:             PASS
```

## The particularly important piece

**Intermediate-output rediscovery**

The agent started with a CSV.  
R changed the world by creating a PNG.  
That new object had an entirely different capability graph, so RIGHTCLICK could expose ImageOptim.

```text
STATE 0
CSV exists
Available relevant ability → R

STATE 1
Chart.png now exists
Available relevant ability → ImageOptim

STATE 2
Optimised chart exists
Goal satisfied
```

That starts to look less like “tools” and more like a **dynamic planning runtime**.

## 20-second demo

> I asked the AI to turn a CSV into something ready for my website. I never told it what apps to use. It discovered R was installed, used R to make the chart, noticed the resulting image could be improved with ImageOptim, discovered that capability too, optimised the chart, and verified the output. Neither app has an MCP.

That is much stronger than: “RIGHTCLICK exposes macOS Services.”
