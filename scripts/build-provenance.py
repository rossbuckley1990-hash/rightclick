#!/usr/bin/env python3
"""Embed development source facts without inferring release acceptance."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expected-commit")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent

    def git(*arguments):
        return subprocess.check_output(["git", "-C", str(root), *arguments], text=True).strip()

    commit = git("rev-parse", "HEAD")
    if args.expected_commit and args.expected_commit != commit:
        parser.error("Source HEAD changed before the accepted build.")
    remote = git("remote", "get-url", "origin")
    canonical = "https://github.com/rossbuckley1990-hash/rightclick"
    if remote not in (canonical, canonical + ".git", "git@github.com:rossbuckley1990-hash/rightclick.git"):
        parser.error("Source repository does not match RIGHTCLICK's canonical repository.")
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal"))
    # Stable/Edge promotion requires reviewed CI/release evidence. This producer
    # cannot turn a local tag, environment variable or branch name into that claim.
    content = "\n".join([
        "// Generated development build facts. Do not commit.",
        "enum RightClickCompiledBuildMetadata {",
        '    static let channel = "development"',
        "    static let gitCommit = " + json.dumps(commit),
        "    static let sourceRepository = " + json.dumps(canonical),
        "    static let sourceDirty = " + str(dirty).lower(),
        "}", "",
    ]).encode()
    expected = root / "Sources/RightClickCore/BuildMetadata.generated.swift"
    if args.output.absolute() != expected:
        parser.error("Build metadata output must be the designated source file.")
    descriptor = os.open(expected, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        expected.unlink(missing_ok=True)
        raise
    print(json.dumps({"channel": "development", "gitCommit": commit, "sourceDirty": dirty}))


if __name__ == "__main__":
    main()
