# Launch copy — prepared, unpublished

Repository description: Install an app. Your AI learns what it can do.

Show HN title: RIGHTCLICK — install a Mac app and your AI learns what it can do

RIGHTCLICK lets an AI discover useful capabilities already exposed by software on your Mac. It reflects existing native contracts into a contextual capability layer, applies policy, and invokes supported actions. MCP connects that layer to your AI.

The proof: the same plain-text query had 36 capabilities and none from third-party software. After installing ordinary BBEdit, it had 41, including five BBEdit capabilities. RIGHTCLICK needed zero BBEdit-specific acquisition changes. The generic executor then put the exact requested text into a new BBEdit document.

This is a bounded test of Capability Reflection, not universal Mac automation. Compatible apps must expose a supported native contract. Finder Action extensions are discovery-only. Some providers accept a call without delivering an independently verified result; Yojam is a documented example. A successful invocation is not enough to claim semantic success.

v0.1.0 targets Apple Silicon/macOS 14+. Publication is pending real Developer ID signing, notarisation, and public Homebrew clean-install acceptance. Replace this status sentence with the verified release install commands only when those gates pass.
