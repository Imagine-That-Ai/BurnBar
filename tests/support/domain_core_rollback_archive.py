from __future__ import annotations

from dataclasses import dataclass, field
import io
import json
import subprocess
import tarfile
from pathlib import Path
from typing import Any


@dataclass
class ArchiveMember:
    name: str
    contents: bytes = b""
    kind: bytes = tarfile.REGTYPE
    linkname: str = ""
    pax_headers: dict[str, str] = field(default_factory=dict)


def source_archive_members(
    candidate: dict[str, Any],
    *,
    version: str,
    source_files: dict[str, bytes],
    extra_repository_files: dict[str, bytes] | None = None,
) -> list[ArchiveMember]:
    manifest = {
        "schemaVersion": 1,
        "coreVersion": candidate["coreVersion"],
        "abiVersion": candidate["abiVersion"],
        "sourceSha256": candidate["sourceSha256"],
        "sourceRoots": ["Cargo.toml", "domain-core/src"],
    }
    repository_files = {
        "crates/openburnbar-domain-core/union-abi-manifest.json": (
            json.dumps(manifest, sort_keys=True).encode() + b"\n"
        ),
        **{
            f"crates/openburnbar-domain-core/{name}": contents
            for name, contents in source_files.items()
        },
        **(extra_repository_files or {}),
    }
    root = f"OpenBurnBar-{version}-legacy-source"
    directories = {root}
    for name in repository_files:
        parts = name.split("/")
        for index in range(1, len(parts)):
            directories.add(f"{root}/{'/'.join(parts[:index])}")
    return [
        *[
            ArchiveMember(name=name, kind=tarfile.DIRTYPE)
            for name in sorted(directories)
        ],
        *[
            ArchiveMember(name=f"{root}/{name}", contents=contents)
            for name, contents in sorted(repository_files.items())
        ],
    ]


def write_pax_source_archive(
    path: Path,
    *,
    candidate_commit: str,
    members: list[ArchiveMember],
) -> None:
    with tarfile.open(
        path,
        "w:gz",
        format=tarfile.PAX_FORMAT,
        pax_headers={"comment": candidate_commit},
    ) as archive:
        for member in members:
            info = tarfile.TarInfo(member.name)
            info.type = member.kind
            info.mode = 0o755 if member.kind == tarfile.DIRTYPE else 0o644
            info.mtime = 0
            info.linkname = member.linkname
            info.pax_headers = dict(member.pax_headers)
            if member.kind == tarfile.REGTYPE:
                info.size = len(member.contents)
                archive.addfile(info, io.BytesIO(member.contents))
            else:
                archive.addfile(info)


def create_candidate_repository(
    root: Path,
    *,
    source_files: dict[str, bytes],
    core_version: str,
    abi_version: int,
    source_sha256: str,
    source_roots: list[str] | None = None,
    extra_repository_files: dict[str, bytes] | None = None,
) -> tuple[Path, str]:
    repository = root / "candidate-repo"
    repository.mkdir()
    manifest = {
        "schemaVersion": 1,
        "coreVersion": core_version,
        "abiVersion": abi_version,
        "sourceSha256": source_sha256,
        "sourceRoots": (
            ["Cargo.toml", "domain-core/src"]
            if source_roots is None
            else source_roots
        ),
    }
    repository_files = {
        "README.md": b"retained candidate source\n",
        "crates/openburnbar-domain-core/union-abi-manifest.json": (
            json.dumps(manifest, sort_keys=True).encode() + b"\n"
        ),
        **{
            f"crates/openburnbar-domain-core/{name}": contents
            for name, contents in source_files.items()
        },
        **(extra_repository_files or {}),
    }
    for name, contents in repository_files.items():
        path = repository / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
    for command in (
        ("git", "init", "--quiet"),
        ("git", "config", "user.name", "BurnBar Tests"),
        ("git", "config", "user.email", "tests@openburnbar.dev"),
        ("git", "config", "commit.gpgsign", "false"),
        ("git", "add", "--all"),
        ("git", "commit", "--quiet", "-m", "candidate"),
    ):
        subprocess.run(command, cwd=repository, check=True)
    commit = subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=repository,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    return repository, commit


def write_git_source_archive(
    repository: Path,
    path: Path,
    *,
    candidate_commit: str,
    version: str,
) -> None:
    with path.open("wb") as output:
        subprocess.run(
            (
                "git",
                "archive",
                "--format=tar.gz",
                f"--prefix=OpenBurnBar-{version}-legacy-source/",
                candidate_commit,
            ),
            cwd=repository,
            check=True,
            stdout=output,
        )
