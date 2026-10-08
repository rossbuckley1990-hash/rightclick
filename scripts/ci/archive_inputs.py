"""Select source-archive inputs from tracked Git paths and working-tree bytes.

Git supplies the allowed names and executable bits. The working tree supplies
the bytes, so reviewed dirty edits are packaged without admitting ignored or
untracked files. This helper does not write the checkout or produce an archive.
"""
from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
from typing import NamedTuple, Sequence


class ArchiveInputError(ValueError):
    pass


class ArchiveInput(NamedTuple):
    relative: PurePosixPath
    mode: int
    is_directory: bool


def _relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (not value or path.is_absolute() or path.as_posix() != value
            or any(part in {".", "..", ".git"} for part in path.parts)
            or "\0" in value or "\\" in value):
        raise ArchiveInputError("Archive inputs must be canonical relative paths")
    return path


def _regular_path(root: Path, relative: PurePosixPath, directory: bool) -> None:
    current = root
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise ArchiveInputError("Missing tracked archive input: " + relative.as_posix()) from error
        expected_directory = directory or index < len(relative.parts) - 1
        if stat.S_ISLNK(mode):
            raise ArchiveInputError("Symlinked archive input or parent: " + relative.as_posix())
        if not (stat.S_ISDIR(mode) if expected_directory else stat.S_ISREG(mode)):
            raise ArchiveInputError("Non-regular archive input: " + relative.as_posix())


def tracked_archive_inputs(root: Path, required: Sequence[str],
                           additional_directories: Sequence[str] = ("scripts",)) -> list[ArchiveInput]:
    root = root.resolve(strict=True)
    if not root.is_dir() or not required:
        raise ArchiveInputError("An existing checkout and required inputs are necessary")
    selected: dict[PurePosixPath, bool] = {}
    for value in [*required, *additional_directories]:
        relative = _relative(value)
        path = root / relative
        try:
            directory = stat.S_ISDIR(path.lstat().st_mode)
        except OSError as error:
            raise ArchiveInputError("Missing required archive path: " + relative.as_posix()) from error
        _regular_path(root, relative, directory)
        if value in additional_directories and not directory:
            raise ArchiveInputError("An additional archive directory is not a directory")
        selected[relative] = directory
    try:
        raw = subprocess.check_output(
            ["git", "-C", os.fspath(root), "ls-files", "--stage", "-z", "--",
             *[":(literal)" + value.as_posix() for value in sorted(selected)]])
    except subprocess.CalledProcessError as error:
        raise ArchiveInputError("Git archive inventory could not be read") from error
    files: dict[PurePosixPath, ArchiveInput] = {}
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        try:
            metadata, name = entry.decode("utf-8").split("\t", 1)
            mode, _, stage = metadata.split()
            relative = _relative(name)
        except (UnicodeError, ValueError) as error:
            raise ArchiveInputError("Malformed Git archive inventory entry") from error
        if stage != "0":
            raise ArchiveInputError("Unmerged archive input: " + relative.as_posix())
        if mode not in {"100644", "100755"}:
            raise ArchiveInputError("Unsupported tracked archive file mode: " + relative.as_posix())
        if relative in files:
            raise ArchiveInputError("Duplicate Git archive input: " + relative.as_posix())
        if not any(relative == path or directory and path in relative.parents
                   for path, directory in selected.items()):
            raise ArchiveInputError("Git returned a path outside the archive inputs")
        _regular_path(root, relative, False)
        files[relative] = ArchiveInput(relative, int(mode, 8) & 0o777, False)
    for relative, directory in selected.items():
        included = (any(relative in path.parents for path in files) if directory else relative in files)
        if not included:
            raise ArchiveInputError("Required archive path has no tracked files: " + relative.as_posix())
    inputs = dict(files)
    for relative in files:
        for parent in relative.parents:
            if parent == PurePosixPath("."):
                continue
            _regular_path(root, parent, True)
            inputs[parent] = ArchiveInput(parent, 0o755, True)
    return [inputs[path] for path in sorted(inputs)]
