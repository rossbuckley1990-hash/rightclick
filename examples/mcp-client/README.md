# Minimal RIGHTCLICK MCP client

Talks to `rightclick mcp` over stdio with the Python standard library. No third-party deps.

## Prerequisites

```bash
brew install rossbuckley1990-hash/tap/rightclick
# or: scripts/build-cli.sh from a checkout
```

## Run

```bash
python3 client.py
# or point at a local build:
RIGHTCLICK_BIN=./.build/release/rightclick python3 client.py
```

The script initializes the server, lists tools, discovers actions for a plain-text item, explains the first non-Apple action if any, and shows (but does not execute) a confirmed `context_run` payload.
