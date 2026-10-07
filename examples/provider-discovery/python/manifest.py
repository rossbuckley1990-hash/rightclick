#!/usr/bin/env python3
"""Emit optional metadata for one existing standard; no RIGHTCLICK dependency."""
from __future__ import annotations

import argparse
import json
import re


def discovery_json(kind: str, path: str) -> str:
    if kind not in ("openapi", "graphql", "mcp"):
        raise ValueError("Supported manifest links are openapi, graphql and mcp.")
    if (not isinstance(path, str) or len(path) > 4096 or
            re.fullmatch(r"/(?:[A-Za-z0-9._~-]+(?:/[A-Za-z0-9._~-]+)*)?", path) is None or
            any(segment in (".", "..") for segment in path.split("/"))):
        raise ValueError("Use a bounded root-relative ASCII declaration path without authority, escapes, traversal, query or fragment.")
    return json.dumps({"schemaVersion": 1, "links": [{"kind": kind, "url": path}]}, separators=(",", ":"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("openapi", "graphql", "mcp"))
    parser.add_argument("path")
    args = parser.parse_args()
    try:
        document = discovery_json(args.kind, args.path)
    except ValueError as error:
        parser.error(str(error))
    print(document)


if __name__ == "__main__":
    main()
