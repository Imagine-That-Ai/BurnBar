"""Canonical byte-level fingerprinting for domain-core source files."""

from __future__ import annotations

import hashlib
from collections.abc import Mapping


def source_fingerprint(files: Mapping[str, bytes]) -> str:
    digest = hashlib.sha256()
    for path in sorted(files):
        relative = path.encode()
        contents = files[path]
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()
