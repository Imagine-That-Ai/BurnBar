"""Exercise the pin verifier against real Gradle declarations and drifted copies."""

import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
GRADLE = Path("android/app/build.gradle.kts")
VERIFIER = Path("scripts/ci/verify-libsignal-pin.sh")


@pytest.fixture
def pin_tree(tmp_path: Path) -> Path:
    for relative in (
        GRADLE,
        VERIFIER,
        Path("third_party/libsignal/manifest.json"),
        Path("third_party/libsignal/runtime-readiness.json"),
        Path("packages/libsignal-bridge/package.json"),
        Path("packages/libsignal-bridge/package-lock.json"),
    ):
        destination = tmp_path / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO_ROOT / relative, destination)
    return tmp_path


def verify(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["bash", str(root / VERIFIER)], capture_output=True, text=True, check=False)


def test_actual_android_and_node_pins_agree(pin_tree: Path) -> None:
    result = verify(pin_tree)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("artifact", ("libsignal-android", "libsignal-client"))
@pytest.mark.parametrize("mutation", ("drift", "missing", "duplicate", "dynamic", "commented"))
def test_android_pin_drift_fails_closed(pin_tree: Path, artifact: str, mutation: str) -> None:
    gradle = pin_tree / GRADLE
    source = gradle.read_text()
    coordinate = f"org.signal:{artifact}:0.103.0"
    assert source.count(coordinate) == 1
    replacements = {
        "drift": coordinate.replace("0.103.0", "0.106.1"),
        "missing": f"removed:{artifact}:0.103.0",
        "duplicate": f'{coordinate}")\n    implementation("{coordinate}',
        "dynamic": coordinate.replace("0.103.0", "$signalVersion"),
    }
    if mutation == "commented":
        source = "\n".join(f"// {line}" if coordinate in line else line for line in source.split("\n"))
    else:
        source = source.replace(coordinate, replacements[mutation])
    gradle.write_text(source)
    result = verify(pin_tree)
    assert result.returncode != 0
    assert f"exactly one pinned org.signal:{artifact}:0.103.0" in result.stderr
