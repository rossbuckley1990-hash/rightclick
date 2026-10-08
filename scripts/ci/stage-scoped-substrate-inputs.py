#!/usr/bin/env python3
"""Stage exactly four private, existing scoped inputs; never stage admin state."""
import argparse
import os
import pathlib
import stat


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    args.destination.mkdir(mode=0o700)
    for name in ["scoped.kubeconfig", "observer.kubeconfig", "kafka-publisher.json", "kafka-observer.json"]:
        source = args.source / name
        mode = source.lstat()
        if not stat.S_ISREG(mode.st_mode) or mode.st_uid != os.geteuid() or stat.S_IMODE(mode.st_mode) != 0o600 or mode.st_nlink != 1:
            raise SystemExit("Unsafe scoped fixture input; values withheld")
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            current = os.fstat(descriptor)
            if (mode.st_dev, mode.st_ino, mode.st_mode, mode.st_uid, mode.st_nlink) != (current.st_dev, current.st_ino, current.st_mode, current.st_uid, current.st_nlink):
                raise SystemExit("Scoped fixture input changed during staging; values withheld")
            data = os.read(descriptor, 1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise SystemExit("Scoped fixture input exceeded the staging bound")
        finally:
            os.close(descriptor)
        target = args.destination / name
        target.write_bytes(data)
        target.chmod(0o600)
    print("Staged four private scoped writer/observer inputs; admin state excluded")


if __name__ == "__main__":
    main()
