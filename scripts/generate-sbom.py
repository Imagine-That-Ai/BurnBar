#!/usr/bin/env python3
"""
generate-sbom.py — Merge lockfile dependency data into an SPDX SBOM for OpenBurnBar.

Usage:
    scripts/generate-sbom.py --version VERSION [--repo-root PATH] [--output PATH]

Collects dependency information from:
  - Swift Package Manager Package.resolved files
  - npm package-lock.json files across app, functions, services, tools, and website
  - Cargo.lock files for Rust crates

Produces an SPDX 2.3 JSON SBOM with:
  - The OpenBurnBar application as the top-level package
  - All runtime and development dependencies as related packages

Prerequisites:
    - Python 3.9+ (no external dependencies)
"""

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from hashlib import sha256
from urllib.parse import quote


def run(cmd: list[str], cwd: str | None = None, check: bool = True) -> str:
    """Run a command and return its stdout."""
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, check=False)
    if check and result.returncode != 0:
        print(f"WARNING: Command failed: {' '.join(cmd)}", file=sys.stderr)
        print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        return ""
    return result.stdout.strip()


def relative_to_repo(repo_root: Path, path: Path) -> str:
    try:
        return str(path.relative_to(repo_root))
    except ValueError:
        return str(path)


def collect_spm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from SwiftPM Package.resolved lockfiles."""
    packages = []
    for lock_file in sorted(repo_root.rglob("Package.resolved")):
        if ".build" in lock_file.parts:
            continue
        try:
            lock_data = json.loads(lock_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"WARNING: Could not parse {lock_file}: {exc}", file=sys.stderr)
            continue

        source_path = relative_to_repo(repo_root, lock_file)
        for pin in lock_data.get("pins", []):
            state = pin.get("state", {})
            url = pin.get("location", "")
            name = pin.get("identity") or Path(str(url).removesuffix(".git")).name
            version = state.get("version") or state.get("revision") or state.get("branch") or "unknown"
            packages.append({
                "name": name,
                "version": version,
                "url": url or "NOASSERTION",
                "type": "spm",
                "source_path": source_path,
            })

    return packages


def collect_npm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from every npm package-lock.json in the repo."""
    packages = []

    for lock_file in sorted(repo_root.rglob("package-lock.json")):
        if "node_modules" in lock_file.parts:
            continue
        try:
            lock_data = json.loads(lock_file.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            print(f"WARNING: Could not parse {lock_file}: {exc}", file=sys.stderr)
            continue

        source_path = relative_to_repo(repo_root, lock_file)
        lock_packages = lock_data.get("packages", {})
        if lock_packages:
            for package_path, package_data in lock_packages.items():
                if not package_path or "node_modules/" not in package_path:
                    continue
                dep_name = package_path.rsplit("node_modules/", 1)[1]
                version = str(package_data.get("version", "")).strip()
                if not dep_name or not version:
                    continue
                packages.append({
                    "name": dep_name,
                    "version": version,
                    "url": package_data.get("resolved") or f"https://www.npmjs.com/package/{dep_name}",
                    "type": "npm",
                    "license": package_data.get("license"),
                    "integrity": package_data.get("integrity"),
                    "source_path": source_path,
                })
            continue

        # package-lock v1 fallback.
        def visit_dependencies(dependencies: dict) -> None:
            for dep_name, dep_data in dependencies.items():
                version = str(dep_data.get("version", "")).strip()
                if version:
                    packages.append({
                        "name": dep_name,
                        "version": version,
                        "url": dep_data.get("resolved") or f"https://www.npmjs.com/package/{dep_name}",
                        "type": "npm",
                        "integrity": dep_data.get("integrity"),
                        "source_path": source_path,
                    })
                visit_dependencies(dep_data.get("dependencies", {}))

        visit_dependencies(lock_data.get("dependencies", {}))

    return packages


def collect_cargo_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from Cargo.lock files."""
    packages = []
    assignment = re.compile(r'^([A-Za-z0-9_-]+)\s*=\s*"(.*)"$')

    for lock_file in sorted(repo_root.rglob("Cargo.lock")):
        if "target" in lock_file.parts:
            continue
        source_path = relative_to_repo(repo_root, lock_file)
        current: dict | None = None

        def flush() -> None:
            if not current:
                return
            name = current.get("name")
            version = current.get("version")
            if not name or not version:
                return
            source = current.get("source", "")
            url = source
            if source.startswith("registry+https://github.com/rust-lang/crates.io-index"):
                url = f"https://crates.io/crates/{name}"
            packages.append({
                "name": name,
                "version": version,
                "url": url or "NOASSERTION",
                "type": "cargo",
                "checksum": current.get("checksum"),
                "source_path": source_path,
            })

        try:
            lines = lock_file.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            print(f"WARNING: Could not read {lock_file}: {exc}", file=sys.stderr)
            continue

        for line in lines:
            stripped = line.strip()
            if stripped == "[[package]]":
                flush()
                current = {}
                continue
            if current is None:
                continue
            match = assignment.match(stripped)
            if match:
                current[match.group(1)] = match.group(2)
        flush()

    return packages


def deduplicate_dependencies(deps: list[dict]) -> list[dict]:
    """Merge duplicate package manager entries while preserving source lockfiles."""
    merged: dict[tuple[str, str, str], dict] = {}
    for dep in deps:
        name = str(dep.get("name", "")).strip()
        version = str(dep.get("version", "unknown")).strip() or "unknown"
        dep_type = str(dep.get("type", "unknown")).strip()
        if not name:
            continue
        key = (dep_type, name, version)
        target = merged.setdefault(key, {
            "type": dep_type,
            "name": name,
            "version": version,
            "url": dep.get("url") or "NOASSERTION",
            "sources": [],
        })
        if target["url"] == "NOASSERTION" and dep.get("url"):
            target["url"] = dep["url"]
        for optional in ("license", "integrity", "checksum"):
            if optional not in target and dep.get(optional):
                target[optional] = dep[optional]
        source_path = dep.get("source_path")
        if source_path and source_path not in target["sources"]:
            target["sources"].append(source_path)
    return sorted(merged.values(), key=lambda dep: (dep["type"], dep["name"], dep["version"]))


def build_spdx_document(
    version: str,
    repo_root: Path,
    deps: list[dict],
) -> dict:
    """Build an SPDX 2.3 JSON document."""
    spdx_id = "SPDXRef-DOCUMENT"
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    commit = run(["git", "rev-parse", "HEAD"], cwd=str(repo_root), check=False) or "unknown"

    packages = [
        {
            "SPDXID": "SPDXRef-Package-openburnbar",
            "name": "OpenBurnBar",
            "versionInfo": version,
            "downloadLocation": f"https://github.com/Ajnunezg/BurnBar/tree/v{version}",
            "filesAnalyzed": False,
            "supplier": "Organization: Ajnunezg",
            "copyrightText": "NOASSERTION",
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE_MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": f"pkg:github/Ajnunezg/BurnBar@v{version}",
                }
            ],
        }
    ]

    relationships = [
        {
            "spdxElementId": spdx_id,
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-openburnbar",
        }
    ]

    purl_types = {
        "cargo": "cargo",
        "npm": "npm",
        "spm": "swift",
    }

    for i, dep in enumerate(deps, start=1):
        dep_spdx_id = f"SPDXRef-Package-dep-{i:04d}"
        purl_type = purl_types.get(dep["type"], "generic")
        purl_name = quote(dep["name"], safe="/" if purl_type == "npm" else "")
        purl = f"pkg:{purl_type}/{purl_name}"
        if dep["version"] != "unknown":
            purl += f"@{quote(dep['version'], safe='')}"

        pkg = {
            "SPDXID": dep_spdx_id,
            "name": dep["name"],
            "versionInfo": dep["version"],
            "downloadLocation": dep.get("url", "NOASSERTION"),
            "filesAnalyzed": False,
            "copyrightText": "NOASSERTION",
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": dep.get("license") or "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE_MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": purl,
                }
            ],
            "comment": f"Package manager: {dep['type']}; observed in: {', '.join(dep.get('sources') or ['unknown'])}",
        }
        checksum = dep.get("checksum")
        if checksum and re.fullmatch(r"[0-9a-fA-F]{64}", checksum):
            pkg["checksums"] = [{"algorithm": "SHA256", "checksumValue": checksum.lower()}]
        packages.append(pkg)

        relationships.append({
            "spdxElementId": "SPDXRef-Package-openburnbar",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": dep_spdx_id,
        })

    commit_for_ns = commit if re.fullmatch(r"[0-9a-f]{40}", commit) else "unknown"
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": spdx_id,
        "name": f"OpenBurnBar v{version}",
        "documentNamespace": f"https://github.com/Ajnunezg/BurnBar/sbom/v{version}/{commit_for_ns}",
        "creationInfo": {
            "created": now,
            "creators": [
                "Tool: generate-sbom.py",
                f"Tool: git+{commit[:12]}",
            ],
        },
        "packages": packages,
        "relationships": relationships,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate SPDX SBOM for OpenBurnBar")
    parser.add_argument("--version", required=True, help="Release version (e.g. 0.2.0)")
    parser.add_argument("--repo-root", default=".", help="Path to repo root")
    parser.add_argument("--output", default=None, help="Output path (default: sbom-vVERSION.spdx.json)")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    version = args.version.strip().lstrip("v")
    output = Path(args.output) if args.output else repo_root / f"sbom-v{version}.spdx.json"

    print(f"Generating SBOM for OpenBurnBar v{version}...")
    print(f"  Repo root: {repo_root}")

    spm_deps = collect_spm_dependencies(repo_root)
    print(f"  SPM dependencies: {len(spm_deps)}")

    npm_deps = collect_npm_dependencies(repo_root)
    print(f"  npm dependencies: {len(npm_deps)}")

    cargo_deps = collect_cargo_dependencies(repo_root)
    print(f"  Cargo dependencies: {len(cargo_deps)}")

    deps = deduplicate_dependencies(spm_deps + npm_deps + cargo_deps)
    print(f"  Deduplicated dependency packages: {len(deps)}")

    doc = build_spdx_document(version, repo_root, deps)

    with open(output, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=False)

    print(f"  Total packages: {len(doc['packages'])}")
    print(f"  Written to: {output}")


if __name__ == "__main__":
    main()
