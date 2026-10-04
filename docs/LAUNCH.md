# Launch copy

Not published. Repository name: `rightclick`.

## GitHub description

Install an app. Your AI learns what it can do.

## Topics

mcp, ai-agents, macos, swift, model-context-protocol, automation, agents, appkit

## Show HN

Show HN: RIGHTCLICK – install a Mac app and your AI learns what it can do

RIGHTCLICK is a small MCP server for macOS. It does not ship a catalogue of hard-coded app tools. It asks the system which contextual capabilities already apply to a file, a piece of text, or a URL, and it exposes those as six MCP tools.

The test I care about: plain text had 36 capabilities and no third-party ones. I installed ordinary BBEdit 16.0.3 and changed no RIGHTCLICK code. The same query returned 41 capabilities, five of them from BBEdit's normal macOS Services. One of those, New BBEdit Document with Selection, opened BBEdit with the exact text I sent.

Action Extensions are discovered and are not generically executable. A successful service call is not the same thing as a proven side effect. v0.1 is an arm64 source build. A signed, notarised Homebrew install is not up yet.

## Social

RIGHTCLICK lets an AI use capabilities already installed on your Mac.

Install ordinary BBEdit. Change no RIGHTCLICK code. Text capabilities go from 36 to 41, and five of the new ones are BBEdit Services. New BBEdit Document with Selection then opens BBEdit with the exact text.

It is not a list of hard-coded app tools. v0.1 discovers macOS Services, sharing services, and Action Extension metadata. Action Extensions are not generically executable yet, and the signed download is still to come.
