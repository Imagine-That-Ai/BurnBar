"""Shared fixtures for the BurnBar compliance test suite."""

from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]


def require_built_artifacts(*rel_paths: str) -> None:
    """Skip (never silently pass) when a smoke test's built inputs are absent.

    Mirrors the posture checker's "skipped (no iOS artifact)" rule: runtime
    smoke tests against compiled functions output only run where that output
    has been built (npm ci + npm run build in functions/). A missing artifact
    is an honest skip, not a green check.
    """
    missing = [rel for rel in rel_paths if not (REPO_ROOT / rel).exists()]
    if missing:
        pytest.skip("requires built artifacts: " + ", ".join(missing))
