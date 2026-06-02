#!/usr/bin/env python3
"""Validate CI and supply-chain workflow invariants for OpenBurnBar."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIRS = [
    REPO_ROOT / ".github" / "workflows",
    REPO_ROOT / ".github" / "actions",
]

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
USES_RE = re.compile(r"\buses:\s*([^#\s]+)")
RUN_RE = re.compile(r"^(\s*)run:\s*(.*)$")
CURL_PIPE_RE = re.compile(r"\bcurl\b[^\n|]*\|[^\n]*(?:ba)?sh\b")
REMOTE_INSTALLER_RE = re.compile(
    r"(raw\.githubusercontent\.com/rhysd/actionlint/.*/download-actionlint\.bash|"
    r"app\.factory\.ai/cli|"
    r"sentry\.io/get-cli)"
)
DIRECT_INPUT_CONTEXTS = (
    "${{ inputs.",
    "${{ github.event.inputs",
    "${{ github.base_ref",
)
SCOPED_WORKFLOWS = {
    ".github/workflows/release.yml",
    ".github/workflows/nightly-e2e.yml",
    ".github/workflows/qa.yml",
    ".github/workflows/fast-feedback.yml",
    ".github/workflows/deploy-production.yml",
    ".github/workflows/droid-wiki-refresh.yml",
    ".github/workflows/computer-use-loopback-test.yml",
}
TRUSTED_TAG_WORKFLOWS = (
    ".github/workflows/release.yml",
    ".github/workflows/deploy-production.yml",
)


def workflow_files() -> list[Path]:
    files: list[Path] = []
    for directory in WORKFLOW_DIRS:
        if directory.exists():
            files.extend(directory.rglob("*.yml"))
            files.extend(directory.rglob("*.yaml"))
    return sorted(files)


def rel(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT))


def validate_action_pins(path: Path, text: str, errors: list[str]) -> None:
    for line_no, line in enumerate(text.splitlines(), start=1):
        match = USES_RE.search(line)
        if not match:
            continue
        spec = match.group(1)
        if spec.startswith("./") or spec.startswith("docker://"):
            continue
        if "@" not in spec:
            errors.append(f"{rel(path)}:{line_no}: external action is missing an immutable ref: {spec}")
            continue
        ref = spec.rsplit("@", 1)[1]
        if not SHA_RE.fullmatch(ref):
            errors.append(f"{rel(path)}:{line_no}: external action must be pinned to a 40-character SHA: {spec}")


def validate_installers(path: Path, text: str, errors: list[str]) -> None:
    for line_no, line in enumerate(text.splitlines(), start=1):
        if CURL_PIPE_RE.search(line):
            errors.append(f"{rel(path)}:{line_no}: remote curl output must not be piped to a shell")
        if REMOTE_INSTALLER_RE.search(line):
            errors.append(f"{rel(path)}:{line_no}: use a local verified installer script instead of a mutable remote installer")


def run_block_lines(lines: list[str]) -> list[tuple[int, str]]:
    collected: list[tuple[int, str]] = []
    in_block = False
    block_indent = 0
    content_indent = 0

    for idx, line in enumerate(lines, start=1):
        if in_block:
            if line.strip() and (len(line) - len(line.lstrip(" "))) < content_indent:
                in_block = False
            else:
                collected.append((idx, line))
                continue

        match = RUN_RE.match(line)
        if not match:
            continue
        block_indent = len(match.group(1))
        payload = match.group(2).strip()
        if payload in {"|", "|-", ">", ">-"}:
            in_block = True
            content_indent = block_indent + 2
            continue
        collected.append((idx, payload))

    return collected


def validate_run_interpolation(path: Path, text: str, errors: list[str]) -> None:
    for line_no, line in run_block_lines(text.splitlines()):
        compact = re.sub(r"\s+", " ", line)
        if any(context in compact for context in DIRECT_INPUT_CONTEXTS):
            errors.append(
                f"{rel(path)}:{line_no}: untrusted workflow inputs/base refs must enter shell via env and validation"
            )


def validate_checkout_credentials(path: Path, text: str, errors: list[str]) -> None:
    if rel(path) not in SCOPED_WORKFLOWS:
        return
    lines = text.splitlines()
    for idx, line in enumerate(lines):
        if "uses: actions/checkout@" not in line:
            continue
        window = "\n".join(lines[idx : idx + 6])
        if "persist-credentials: false" not in window:
            errors.append(f"{rel(path)}:{idx + 1}: actions/checkout must set persist-credentials: false")


def validate_trusted_release_checkout(errors: list[str]) -> None:
    needle = "scripts/security/resolve-trusted-release-tag.sh"
    trusted_ref = "ref: ${{ github.event.repository.default_branch }}"
    for workflow in TRUSTED_TAG_WORKFLOWS:
        path = REPO_ROOT / workflow
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        before_resolver = text.split(needle, 1)[0]
        if trusted_ref not in before_resolver:
            errors.append(
                f"{workflow}: checkout before trusted tag resolution must use the default branch, not the event ref"
            )


def validate_manual_secret_gates(errors: list[str]) -> None:
    nightly = (REPO_ROOT / ".github/workflows/nightly-e2e.yml").read_text(encoding="utf-8")
    if "TRUSTED_SECRET_REF:" not in nightly or "github.ref == 'refs/heads/main'" not in nightly:
        errors.append(".github/workflows/nightly-e2e.yml: Firebase/App Check secrets must be gated to schedule/main refs")
    if "github.ref == 'refs/heads/main') && secrets.FIREBASE_PLIST_BASE64" not in nightly:
        errors.append(".github/workflows/nightly-e2e.yml: App Check token injection must not run on manual selected refs")

    qa = (REPO_ROOT / ".github/workflows/qa.yml").read_text(encoding="utf-8")
    expected = "TRUSTED_SECRET_CONTEXT: ${{ github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' }}"
    if expected not in qa:
        errors.append(".github/workflows/qa.yml: secret-backed Droid QA must be restricted to workflow_dispatch on main")


def validate_pinned_toolchains(errors: list[str]) -> None:
    fast_feedback = (REPO_ROOT / ".github/workflows/fast-feedback.yml").read_text(encoding="utf-8")
    if 'toolchain: "1.94.0"' not in fast_feedback:
        errors.append(".github/workflows/fast-feedback.yml: Rust toolchain must be pinned to 1.94.0")
    if "cargo install cargo-deny --version 0.19.8 --locked" not in fast_feedback:
        errors.append(".github/workflows/fast-feedback.yml: cargo-deny install must pin version 0.19.8")


def validate_pinned_installers(errors: list[str]) -> None:
    sentry = (REPO_ROOT / "scripts/supply-chain/install-sentry-cli.sh").read_text(encoding="utf-8")
    if "expected_digest=" not in sentry or "release-registry.services.sentry.io/apps/sentry-cli/${version}" not in sentry:
        errors.append("scripts/supply-chain/install-sentry-cli.sh: sentry-cli installer must verify a repo-pinned digest")
    if "-D \"$headers\"" in sentry or 'name.lower() == "digest"' in sentry:
        errors.append("scripts/supply-chain/install-sentry-cli.sh: sentry-cli digest must not be trusted from response headers")

    droid = (REPO_ROOT / "scripts/supply-chain/install-factory-droid.sh").read_text(encoding="utf-8")
    if "expected=" not in droid or "0.138.0:linux:x64" not in droid:
        errors.append("scripts/supply-chain/install-factory-droid.sh: Factory Droid installer must verify repo-pinned checksums")
    if "droid.sha256" in droid:
        errors.append("scripts/supply-chain/install-factory-droid.sh: Factory Droid checksum must not be downloaded at runtime")


def validate_release_tag_resolvers(errors: list[str]) -> None:
    required = [
        ".github/workflows/release.yml",
        ".github/workflows/deploy-production.yml",
        ".github/workflows/supply-chain-provenance.yml",
    ]
    needle = "scripts/security/resolve-trusted-release-tag.sh"
    for workflow in required:
        path = REPO_ROOT / workflow
        if path.exists() and needle not in path.read_text(encoding="utf-8"):
            errors.append(f"{workflow}: release/provenance workflow must resolve trusted signed tags with {needle}")


def validate_provenance_artifact_binding(errors: list[str]) -> None:
    workflow = ".github/workflows/supply-chain-provenance.yml"
    path = REPO_ROOT / workflow
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")
    required = {
        "workflow_run.head_sha": "workflow_run provenance must compare release metadata with workflow_run.head_sha",
        "release-metadata.json": "provenance must read the release metadata artifact",
        "gh release view": "manual provenance dispatch must verify the GitHub Release exists",
        "gh release download": "manual provenance dispatch must download GitHub Release assets",
        "Bind provenance to release artifacts": "provenance must validate downloaded release artifacts before attestation",
        "steps.artifacts.outputs.dmg_path": "provenance must attest/download the release DMG artifact",
        "steps.artifacts.outputs.zip_path": "provenance must attest/download the release ZIP artifact",
        "steps.artifacts.outputs.checksums_path": "provenance must attest/download release checksums",
        "steps.artifacts.outputs.sbom_path": "provenance must use the release-run SBOM artifact",
        "steps.artifacts.outputs.vex_path": "provenance must use the release-run OpenVEX artifact",
    }
    for needle, message in required.items():
        if needle not in text:
            errors.append(f"{workflow}: {message}")
    forbidden = (
        "PR-style fallback when artifacts missing",
        "python3 scripts/generate-sbom.py",
        "python3 scripts/supply-chain/generate-vex.py",
    )
    for needle in forbidden:
        if needle in text:
            errors.append(f"{workflow}: provenance must not regenerate SBOM/VEX instead of attesting release artifacts")


def main() -> int:
    errors: list[str] = []
    for path in workflow_files():
        text = path.read_text(encoding="utf-8")
        validate_action_pins(path, text, errors)
        validate_installers(path, text, errors)
        validate_run_interpolation(path, text, errors)
        validate_checkout_credentials(path, text, errors)
    validate_release_tag_resolvers(errors)
    validate_provenance_artifact_binding(errors)
    validate_trusted_release_checkout(errors)
    validate_manual_secret_gates(errors)
    validate_pinned_toolchains(errors)
    validate_pinned_installers(errors)

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"CI supply-chain validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1

    print("CI supply-chain workflow invariants passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
