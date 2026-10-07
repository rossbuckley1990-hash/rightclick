# Minimal RIGHTCLICK MCP client

A bounded, read-only Python standard-library example for the stable macOS runtime. It initializes stdio, verifies exactly seven canonical operations, attests the actual executable bytes, inspects an item, discovers its current capabilities and explains one discovered ID. It invokes no capability and changes no client configuration.

```bash
brew install rossbuckley1990-hash/tap/rightclick
python3 examples/mcp-client/client.py
```

Use another reviewed executable explicitly:

```bash
RIGHTCLICK_BIN=./.build/release/rightclick python3 examples/mcp-client/client.py
```

A matching version string is not equivalent source or behavior. Actual native Windows/Linux candidate acceptance and setup are separate from this installed macOS example. Static site assets are optional documentation; the manual Pages workflow requires Pages configuration and a reviewed deployment. Their presence does not prove a live site.
