#!/usr/bin/env python3
"""
generate-sbom.py — Merge dependency data into an SPDX SBOM for OpenBurnBar.

Usage:
    scripts/generate-sbom.py --version VERSION [--repo-root PATH] [--output PATH]

Collects dependency information from tracked manifests and lockfiles:
  - Swift Package Manager (Package.resolved pins)
  - npm (all tracked package-lock.json files plus package.json fallbacks)
  - Cargo (all tracked Cargo.lock files)
  - Android/Gradle (tracked build.gradle.kts dependency coordinates)

Produces an SPDX 2.3 JSON SBOM with:
  - The OpenBurnBar application as the top-level package
  - All runtime and development dependencies as related packages

Prerequisites:
    - Python 3.9+ (no external dependencies)
    - git (to enumerate tracked manifest files)
"""

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
import re
from urllib.parse import quote


def run(cmd: list[str], cwd: str | None = None, check: bool = True) -> str:
    """Run a command and return its stdout."""
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, check=False)
    if check and result.returncode != 0:
        print(f"WARNING: Command failed: {' '.join(cmd)}", file=sys.stderr)
        print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        return ""
    return result.stdout.strip()


def git_tracked_files(repo_root: Path, *patterns: str) -> list[Path]:
    """Return tracked files matching one or more git pathspecs."""
    output = run(["git", "ls-files", *patterns], cwd=str(repo_root), check=False)
    if not output:
        return []
    return [repo_root / line for line in output.splitlines() if line.strip()]


def dedupe_packages(packages: list[dict]) -> list[dict]:
    """Deduplicate package records while preserving deterministic order."""
    seen: set[tuple[str, str, str]] = set()
    out: list[dict] = []
    for package in sorted(
        packages,
        key=lambda item: (
            item.get("type", ""),
            item.get("name", ""),
            item.get("version", ""),
            item.get("source", ""),
        ),
    ):
        key = (package.get("type", ""), package.get("name", ""), package.get("version", ""))
        if key in seen:
            continue
        seen.add(key)
        out.append(package)
    return out


def package_lock_name_from_path(path: str, meta: dict) -> str:
    """Resolve a package name from a package-lock v3 packages key."""
    if isinstance(meta.get("name"), str) and meta["name"]:
        return meta["name"]
    marker = "node_modules/"
    if marker not in path:
        return ""
    return path.rsplit(marker, 1)[-1]


def npm_package_url(name: str, package_path: str, meta: dict) -> str:
    """Resolve an SBOM download location for npm lockfile entries."""
    resolved = meta.get("resolved")
    if isinstance(resolved, str) and resolved:
        if resolved.startswith((".", "/")):
            return f"file:{resolved}"
        return resolved
    if package_path.startswith((".", "/")):
        return f"file:{package_path}"
    return f"https://www.npmjs.com/package/{name}"


def collect_spm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from tracked SwiftPM Package.resolved files."""
    packages = []
    for resolved in git_tracked_files(repo_root, "Package.resolved", "**/Package.resolved"):
        try:
            pkg_data = json.loads(resolved.read_text())
        except (json.JSONDecodeError, OSError):
            print(f"WARNING: Could not parse Package.resolved at {resolved}", file=sys.stderr)
            continue

        rel = str(resolved.relative_to(repo_root))
        for pin in pkg_data.get("pins", []):
            state = pin.get("state", {})
            location = pin.get("location", "")
            name = pin.get("identity") or pin.get("package") or Path(str(location)).stem.replace(".git", "")
            version = state.get("version") or state.get("revision") or state.get("branch") or "unknown"
            if not name:
                continue
            packages.append({
                "name": name,
                "version": str(version),
                "url": location,
                "type": "spm",
                "source": rel,
            })

    return dedupe_packages(packages)


def collect_npm_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from tracked npm lockfiles and package manifests."""
    packages = []

    for lock_file in git_tracked_files(repo_root, "**/package-lock.json"):
        try:
            lock_data = json.loads(lock_file.read_text())
        except (json.JSONDecodeError, OSError):
            print(f"WARNING: Could not parse package lock at {lock_file}", file=sys.stderr)
            continue

        rel = str(lock_file.relative_to(repo_root))
        for package_path, meta in (lock_data.get("packages") or {}).items():
            if not package_path:
                continue
            name = package_lock_name_from_path(package_path, meta)
            version = meta.get("version")
            if not name or not version:
                continue
            packages.append({
                "name": name,
                "version": str(version),
                "url": npm_package_url(name, package_path, meta),
                "type": "npm",
                "license": meta.get("license"),
                "source": rel,
            })

    # Include direct manifest dependencies for small internal packages that have
    # no lockfile yet; exact transitive pins will be added once a lock exists.
    for pkg_json in git_tracked_files(repo_root, "**/package.json"):
        if pkg_json.name == "package-lock.json":
            continue
        try:
            pkg_data = json.loads(pkg_json.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        rel = str(pkg_json.relative_to(repo_root))
        for dep_type in ("dependencies", "devDependencies", "optionalDependencies"):
            for dep_name, dep_version_spec in pkg_data.get(dep_type, {}).items():
                if str(dep_version_spec).startswith("file:"):
                    continue
                packages.append({
                    "name": dep_name,
                    "version": str(dep_version_spec).lstrip("^~><= "),
                    "url": f"https://www.npmjs.com/package/{dep_name}",
                    "type": "npm",
                    "license": "NOASSERTION",
                    "source": rel,
                })

    return dedupe_packages(packages)


def collect_cargo_dependencies(repo_root: Path) -> list[dict]:
    """Collect dependencies from tracked Cargo.lock files."""
    packages = []

    for lock_file in git_tracked_files(repo_root, "**/Cargo.lock"):
        rel = str(lock_file.relative_to(repo_root))
        current: dict[str, str] = {}

        def flush(package: dict[str, str], lock_rel: str) -> None:
            if package.get("name") and package.get("version"):
                source = package.get("source", "")
                url = source if source.startswith("git+") else f"https://crates.io/crates/{package['name']}"
                packages.append({
                    "name": package["name"],
                    "version": package["version"],
                    "url": url,
                    "type": "cargo",
                    "source": lock_rel,
                })

        for raw_line in lock_file.read_text().splitlines():
            line = raw_line.strip()
            if line == "[[package]]":
                flush(current, rel)
                current = {}
                continue
            match = re.match(r'^(name|version|source)\s*=\s*"([^"]+)"$', line)
            if match:
                current[match.group(1)] = match.group(2)
        flush(current, rel)

    return dedupe_packages(packages)


def collect_gradle_dependencies(repo_root: Path) -> list[dict]:
    """Collect Android/Gradle dependency coordinates from tracked Kotlin build files."""
    packages = []
    coordinate_re = re.compile(r'"([A-Za-z0-9_.-]+):([A-Za-z0-9_.-]+):([^"@]+)(?:@[^"]+)?"')
    plugin_re = re.compile(r'id\("([^"]+)"\)\s+version\s+"([^"]+)"')

    for gradle_file in git_tracked_files(repo_root, "android/**/*.gradle.kts"):
        rel = str(gradle_file.relative_to(repo_root))
        text = gradle_file.read_text()
        for group, artifact, version in coordinate_re.findall(text):
            packages.append({
                "name": f"{group}:{artifact}",
                "version": version,
                "url": f"https://mvnrepository.com/artifact/{group}/{artifact}",
                "type": "gradle",
                "source": rel,
            })
        for plugin_id, version in plugin_re.findall(text):
            packages.append({
                "name": plugin_id,
                "version": version,
                "url": f"https://plugins.gradle.org/plugin/{plugin_id}",
                "type": "gradle-plugin",
                "source": rel,
            })

    return dedupe_packages(packages)


def build_spdx_document(
    version: str,
    repo_root: Path,
    spm_deps: list[dict],
    npm_deps: list[dict],
    cargo_deps: list[dict],
    gradle_deps: list[dict],
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
        "gradle": "maven",
        "gradle-plugin": "maven",
        "npm": "npm",
        "spm": "swift",
    }

    for i, dep in enumerate(spm_deps + npm_deps + cargo_deps + gradle_deps, start=1):
        dep_spdx_id = f"SPDXRef-Package-dep-{i:04d}"
        purl_type = purl_types.get(dep["type"], "generic")
        purl_name = dep["name"].replace(":", "/") if dep["type"] in ("gradle", "gradle-plugin") else dep["name"]
        purl = f"pkg:{purl_type}/{quote(purl_name, safe='@/')}@{quote(dep['version'], safe='')}"
        declared_license = dep.get("license") or "NOASSERTION"

        pkg = {
            "SPDXID": dep_spdx_id,
            "name": dep["name"],
            "versionInfo": dep["version"],
            "downloadLocation": dep.get("url", "NOASSERTION"),
            "filesAnalyzed": False,
            "copyrightText": "NOASSERTION",
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": declared_license if isinstance(declared_license, str) else "NOASSERTION",
            "externalRefs": [
                {
                    "referenceCategory": "PACKAGE_MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": purl,
                }
            ],
        }
        packages.append(pkg)

        relationships.append({
            "spdxElementId": "SPDXRef-Package-openburnbar",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": dep_spdx_id,
        })

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

    cargo_deps = collect_cargo_dependencies(repo_root)
    print(f"  Cargo dependencies: {len(cargo_deps)}")

    gradle_deps = collect_gradle_dependencies(repo_root)
    print(f"  Gradle dependencies: {len(gradle_deps)}")

    doc = build_spdx_document(version, repo_root, spm_deps, npm_deps, cargo_deps, gradle_deps)

    with open(output, "w") as f:
        json.dump(doc, f, indent=2, sort_keys=False)

    print(f"  Total packages: {len(doc['packages'])}")
    print(f"  Written to: {output}")


if __name__ == "__main__":
    main()
