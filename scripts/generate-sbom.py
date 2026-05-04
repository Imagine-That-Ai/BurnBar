#!/usr/bin/env python3
"""
generate-sbom.py — Merge SPM and npm dependency data into an SPDX SBOM for OpenBurnBar.

Usage:
    scripts/generate-sbom.py --version VERSION [--repo-root PATH] [--output PATH]

Collects dependency information from:
  - Swift Package Manager (OpenBurnBarCore, OpenBurnBarDaemon Package.swift)
  - npm (extensions/openburnbar package.json + package-lock.json)

Produces an SPDX 2.3 JSON SBOM with:
  - The OpenBurnBar application as the top-level package
  - All runtime and development dependencies as related packages

Prerequisites:
    - Python 3.9+ (no external dependencies)
    - Swift tools (for `swift package dump-package`)
    - Node.js (for `npm ls --json`)
"""

import argparse
import json
import os
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


def collect_spm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from SPM Package.swift files."""
    packages = []
    spm_dirs = [
        repo_root / "OpenBurnBarCore",
        repo_root / "OpenBurnBarDaemon",
    ]

    for spm_dir in spm_dirs:
        pkg_manifest = spm_dir / "Package.swift"
        if not pkg_manifest.exists():
            continue

        output = run(
            ["swift", "package", "dump-package"],
            cwd=str(spm_dir),
            check=False,
        )
        if not output:
            continue

        try:
            pkg_data = json.loads(output)
        except json.JSONDecodeError:
            print(f"WARNING: Could not parse dump-package output for {spm_dir}", file=sys.stderr)
            continue

        name = pkg_data.get("name", spm_dir.name)
        for dep in pkg_data.get("dependencies", []):
            # Package.swift dependency format
            for req in dep.get("product", [dep]):
                dep_name = req.get("name", "") or dep.get("identity", "")
                url = dep.get("url", dep.get("location", ""))
                if isinstance(url, dict):
                    url = url.get("url", "")
                if not dep_name and url:
                    dep_name = url.split("/")[-1].replace(".git", "")
                packages.append({
                    "name": dep_name,
                    "version": "unknown",
                    "url": url,
                    "type": "spm",
                })

    return packages


def collect_npm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from the npm extension."""
    ext_dir = repo_root / "extensions" / "openburnbar"
    packages = []

    pkg_json = ext_dir / "package.json"
    if not pkg_json.exists():
        return packages

    try:
        with open(pkg_json) as f:
            pkg_data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return packages

    # Collect from dependencies and devDependencies
    for dep_type in ("dependencies", "devDependencies"):
        for dep_name, dep_version_spec in pkg_data.get(dep_type, {}).items():
            # Try to resolve exact version from package-lock.json
            lock_file = ext_dir / "package-lock.json"
            exact_version = dep_version_spec
            if lock_file.exists():
                try:
                    with open(lock_file) as lf:
                        lock_data = json.load(lf)
                    # package-lock v3 format
                    locked = lock_data.get("packages", {}).get(f"node_modules/{dep_name}", {})
                    exact_version = locked.get("version", dep_version_spec)
                except (json.JSONDecodeError, OSError, KeyError):
                    pass

            packages.append({
                "name": dep_name,
                "version": exact_version.lstrip("^~><= "),
                "url": f"https://www.npmjs.com/package/{dep_name}",
                "type": "npm",
            })

    return packages


def build_spdx_document(
    version: str,
    repo_root: Path,
    spm_deps: list[dict],
    npm_deps: list[dict],
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

    for i, dep in enumerate(spm_deps + npm_deps, start=1):
        dep_spdx_id = f"SPDXRef-Package-dep-{i:04d}"
        purl_type = "swift" if dep["type"] == "spm" else "npm"
        purl = f"pkg:{purl_type}/{quote(dep['name'], safe='')}@{quote(dep['version'], safe='')}"

        pkg = {
            "SPDXID": dep_spdx_id,
            "name": dep["name"],
            "versionInfo": dep["version"],
            "downloadLocation": dep.get("url", "NOASSERTION"),
            "filesAnalyzed": False,
            "copyrightText": "NOASSERTION",
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
        }
        packages.append(pkg)

        relationships.append({
            "spdxElementId": "SPDXRef-Package-openburnbar",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": dep_spdx_id,
        })

    ns = "https://spdx.org/rdf/3.0.0"
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": spdx_id,
        "name": f"OpenBurnBar v{version}",
        "documentNamespace": f"https://github.com/Ajnunezg/BurnBar/sbom/v{version}",
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

    doc = build_spdx_document(version, repo_root, spm_deps, npm_deps)

    with open(output, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=False)

    print(f"  Total packages: {len(doc['packages'])}")
    print(f"  Written to: {output}")


if __name__ == "__main__":
    main()
