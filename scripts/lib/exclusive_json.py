#!/usr/bin/env python3
"""Write durable JSON evidence once without following symlinks."""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any


def _remove_created_file(
    parent_descriptor: int,
    name: str,
    identity: tuple[int, int],
) -> None:
    try:
        metadata = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    if (
        stat.S_ISREG(metadata.st_mode)
        and (metadata.st_dev, metadata.st_ino) == identity
    ):
        os.unlink(name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)


def write_exclusive_json(path: Path, value: dict[str, Any]) -> None:
    """Create an owner-only evidence file and durably persist it.

    Existing files and symlink targets are never replaced. If the write fails,
    cleanup removes only the exact inode created by this invocation.
    """

    path = Path(path)
    if not path.name or path.name in {".", ".."}:
        raise ValueError(f"evidence output must name a file: {path}")
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise ValueError(
            f"evidence output parent must be a real existing directory: {path.parent}"
        )

    parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    parent_flags |= getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(path.parent, parent_flags)
    descriptor = -1
    identity: tuple[int, int] | None = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path.name, flags, 0o600, dir_fd=parent_descriptor)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise OSError(f"evidence output is not a regular file: {path}")
        identity = (metadata.st_dev, metadata.st_ino)
        payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        with os.fdopen(descriptor, "wb") as file:
            descriptor = -1
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        os.fsync(parent_descriptor)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        if identity is not None:
            _remove_created_file(parent_descriptor, path.name, identity)
        raise
    finally:
        os.close(parent_descriptor)
