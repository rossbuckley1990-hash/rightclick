#!/usr/bin/env python3
"""Actual Apple installed Service, selected through the same seven operations.

No replacement Service, mock Mac backend or application removal is performed.
This row is explicitly native macOS-only. Withdrawal remains UNPROVEN.
"""
import argparse
import json
import pathlib


def manifest():
    text = "RightClick123"
    expected = "".join(chr(ord(character) + 0xFEE0) for character in text)
    return {"schemaVersion": 1, "rows": {"macos": {
        "selector": {"id": "service:com.apple.ChineseTextConverterService:convertTextToFullWidth"},
        "item": text, "invoke": {"expectedOutput": expected},
        "readback": {"type": "returned-text", "expected": expected}, "requireVerified": True,
        "verificationBoundary": "Actual installed Apple Convert Text to Full Width Service; exact ASCII input and independent Python Unicode mapping; native macOS only; no RCIR/signature or external-state claim"
    }}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest(), indent=2) + "\n")
    args.output.chmod(0o600)
    print("Selected actual installed native Mac Service; withdrawal stays UNPROVEN")


if __name__ == "__main__":
    main()
