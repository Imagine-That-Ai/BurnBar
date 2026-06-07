import subprocess
from pathlib import Path

from conftest import require_built_artifacts


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_compiled_functions_signal_at_rest_write_smoke() -> None:
    require_built_artifacts("functions/lib", "functions/node_modules/@openburnbar/signal-envelope-contracts")
    subprocess.run(
        ["node", "scripts/ci/check_functions_cloudvault_runtime.js", "--signal-at-rest-write"],
        cwd=REPO_ROOT,
        check=True,
    )


def test_compiled_functions_privacy_backfill_smoke() -> None:
    require_built_artifacts("functions/lib", "functions/node_modules/@openburnbar/signal-envelope-contracts")
    subprocess.run(
        ["node", "scripts/ci/check_functions_cloudvault_runtime.js", "--privacy-backfill"],
        cwd=REPO_ROOT,
        check=True,
    )
