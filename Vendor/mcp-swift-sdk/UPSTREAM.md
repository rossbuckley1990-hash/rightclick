# MCP SDK snapshot

Source: https://github.com/modelcontextprotocol/swift-sdk

Version: 0.12.1

Commit: `a0ae212ebf6eab5f754c3129608bc5557637e605`

The Apache-2.0 license is preserved in LICENSE. Sources/MCP is copied from that immutable commit. The only source change replaces `#if !os(Linux)` with `#if canImport(EventSource)` in HTTPClientTransport.swift. Upstream's manifest supplies EventSource only on Apple hosts, but its source imports it on Windows; Windows now takes the existing portable non-streaming fallback. The local manifest includes only the MCP library and its three direct dependencies. Protocol behavior and server validation are retained.

The SDK's POSIX stdio transport remains the default on macOS/Linux. RIGHTCLICK supplies its own Windows stdio adapter. Remove this snapshot when a released upstream SDK passes the integrated Windows build and transport acceptance gates.
