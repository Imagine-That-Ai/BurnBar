#!/usr/bin/env python3
"""Fail closed on semantic Xcode project drift while tolerating PBX object IDs.

XcodeGen can regenerate stable project content with different 24-character PBX
object identifiers and quoted TEMP_<UUID> package-product identifiers. Those
identifiers are implementation details. Source/test membership, targets, build
settings, entitlements, package products, and shell scripts must already match
the generated project. List order inside `children` / `files` / `targets` is
not the contract: XcodeGen's macOS localized sort and hand-registration can
permute the same members.
"""

from __future__ import annotations

import dataclasses
import difflib
import hashlib
import re
import sys
from pathlib import Path


PBX_ID_PATTERN = r"[A-F0-9]{24}"
TEMP_ID_PATTERN = r"TEMP_[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}"
PBX_ID = re.compile(rf"\b(?:{PBX_ID_PATTERN}|{TEMP_ID_PATTERN})\b")
OBJECTS_DECL = re.compile(r"\bobjects\s*=\s*\{")
# Object headers are one line. Do not use DOTALL + `.*?`: a failed match
# then `offset += 1` rescans the rest of a 1.5MB pbxproj from every byte
# and the drift job times out before it can report membership.
OBJECT_ENTRY = re.compile(
    rf'"?(?P<id>{PBX_ID_PATTERN}|{TEMP_ID_PATTERN})"?'
    rf"(?:[ \t]*/\*[ \t]*(?P<comment>[^*]*?)[ \t]*\*/)?[ \t]*=[ \t]*\{{",
)
ISA = re.compile(r"\bisa\s*=\s*(?P<isa>[A-Za-z0-9_]+)\s*;")
# Multiline OpenStep ID lists (children / files / targets / dependencies).
# Hand-patched pbxproj files often insert new sources in ASCII order while
# XcodeGen 2.45.4 uses macOS localizedStandardCompare. Membership is the
# contract; permutation of the same IDs is not.
# Do not match these lists with `=\s*(\n` + a greedy line-eater: that
# backtracks through the rest of an XCBuildConfiguration `buildSettings`
# block (many `KEY = VALUE;` lines after `GCC_PREPROCESSOR_DEFINITIONS = (`)
# and hung the 15-minute drift job. Scan line-by-line instead.
ID_LIST_OPEN = re.compile(r"=\s*\(\s*$")
ID_LIST_CLOSE = re.compile(r"^[ \t]*\)")
ID_LIST_ENTRY = re.compile(
    rf"^(?P<indent>[ \t]*)"
    rf'(?P<id>"?(?:{PBX_ID_PATTERN}|{TEMP_ID_PATTERN}|PBX_[a-f0-9]+|<PBXID>|[a-f0-9]{{64}})"?)\s*'
    rf"(?:/\*\s*(?P<comment>.*?)\s*\*/\s*)?,?\s*$"
)


@dataclasses.dataclass(frozen=True)
class PBXObject:
    id: str
    comment: str
    body: str


@dataclasses.dataclass(frozen=True)
class ObjectsBlock:
    open_brace: int
    close_brace: int
    objects: list[PBXObject]


def _find_matching_brace(text: str, open_brace: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    i = open_brace
    while i < len(text):
        char = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        else:
            if char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    raise ValueError("unbalanced braces in project.pbxproj")


def _extract_objects_block(text: str) -> ObjectsBlock:
    declaration = OBJECTS_DECL.search(text)
    if declaration is None:
        raise ValueError("objects dictionary not found in project.pbxproj")
    open_brace = text.find("{", declaration.start())
    close_brace = _find_matching_brace(text, open_brace)
    body = text[open_brace + 1 : close_brace]

    objects: list[PBXObject] = []
    offset = 0
    body_len = len(body)
    while offset < body_len:
        while offset < body_len and body[offset] in " \t\r\n":
            offset += 1
        if offset >= body_len:
            break
        match = OBJECT_ENTRY.match(body, offset)
        if match is None:
            newline = body.find("\n", offset)
            if newline == -1:
                break
            offset = newline + 1
            continue
        object_open = open_brace + 1 + match.end() - 1
        object_close = _find_matching_brace(text, object_open)
        object_body = text[object_open + 1 : object_close]
        objects.append(
            PBXObject(
                id=match.group("id"),
                comment=match.group("comment") or "",
                body=object_body,
            )
        )
        next_offset = object_close - open_brace
        if next_offset <= offset:
            raise ValueError("pbxproj object parser did not advance")
        offset = next_offset

    if not objects:
        raise ValueError("no PBX objects parsed from project.pbxproj")
    return ObjectsBlock(open_brace=open_brace, close_brace=close_brace, objects=objects)


def _semantic_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _object_isa(obj: PBXObject) -> str:
    match = ISA.search(obj.body)
    return match.group("isa") if match else "UnknownPBXObject"


def _replace_ids(text: str, replacements: dict[str, str], unknown: str = "<PBXID>") -> str:
    return PBX_ID.sub(lambda match: replacements.get(match.group(0), unknown), text)


def _sort_id_reference_lists(text: str) -> str:
    """Sort membership lists so equivalent source sets compare equal."""

    lines = text.splitlines(keepends=True)
    if not lines:
        return text
    out: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if not ID_LIST_OPEN.search(line.rstrip("\n")):
            out.append(line)
            index += 1
            continue

        entries: list[tuple[str, str]] = []
        indent = ""
        cursor = index + 1
        valid = True
        while cursor < len(lines):
            raw = lines[cursor]
            stripped = raw.rstrip("\n")
            if ID_LIST_CLOSE.match(stripped):
                break
            if not stripped.strip():
                cursor += 1
                continue
            parsed = ID_LIST_ENTRY.match(stripped)
            if parsed is None:
                valid = False
                break
            if not indent:
                indent = parsed.group("indent")
            entries.append((parsed.group("comment") or "", parsed.group("id")))
            cursor += 1
        else:
            valid = False

        if not valid or not entries:
            out.append(line)
            index += 1
            continue

        out.append(line)
        for comment, object_id in sorted(entries, key=lambda item: (item[0], item[1])):
            comment_suffix = f" /* {comment} */" if comment else ""
            out.append(f"{indent}{object_id}{comment_suffix},\n")
        out.append(lines[cursor])
        index = cursor + 1

    return "".join(out)


def _semantic_body(body: str, replacements: dict[str, str], unknown: str = "<PBXID>") -> str:
    return _sort_id_reference_lists(_replace_ids(body, replacements, unknown=unknown))


def _semantic_object_labels(objects: list[PBXObject]) -> dict[str, str]:
    by_id = {obj.id: obj for obj in objects}
    fingerprints = {
        obj.id: _semantic_hash(
            "\n".join(
                [
                    f"isa={_object_isa(obj)}",
                    f"comment={obj.comment}",
                    _semantic_body(obj.body, {}, unknown="<PBXID>"),
                ]
            )
        )
        for obj in objects
    }

    # Iterate a fixed number of rounds so references carry semantic identity
    # without requiring a full OpenStep graph parser. The result is deterministic
    # for equivalent project graphs, including cycles.
    for _ in range(8):
        fingerprints = {
            obj_id: _semantic_hash(
                "\n".join(
                    [
                        f"isa={_object_isa(obj)}",
                        f"comment={obj.comment}",
                        _semantic_body(obj.body, fingerprints, unknown="<PBXID>"),
                    ]
                )
            )
            for obj_id, obj in by_id.items()
        }

    return {obj_id: f"PBX_{fingerprint[:16]}" for obj_id, fingerprint in fingerprints.items()}


def _canonicalize_text(text: str) -> str:
    block = _extract_objects_block(text)
    labels = _semantic_object_labels(block.objects)
    canonical_entries: list[tuple[str, str]] = []
    for obj in block.objects:
        label = labels[obj.id]
        comment = f" /* {obj.comment} */" if obj.comment else ""
        body = _semantic_body(obj.body, labels)
        canonical_entries.append((label, f"\t\t{label}{comment} = {{{body}\t\t}};\n"))

    canonical_body = "\n" + "".join(entry for _, entry in sorted(canonical_entries)) + "\t"
    prefix = _replace_ids(text[: block.open_brace + 1], labels)
    suffix = _replace_ids(text[block.close_brace :], labels)
    return prefix + canonical_body + suffix


def canonical_pbxproj(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
    text = _canonicalize_text(text)
    return text.splitlines(keepends=True)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: verify-xcodegen-pbxproj-drift.py <committed.pbxproj> <generated.pbxproj>",
            file=sys.stderr,
        )
        return 2

    committed_path = Path(argv[1])
    generated_path = Path(argv[2])
    committed = canonical_pbxproj(committed_path)
    generated = canonical_pbxproj(generated_path)

    if committed == generated:
        print("project.pbxproj semantic content is in sync; PBX object ID churn ignored.")
        return 0

    print("project.pbxproj semantic drift detected after normalizing PBX object IDs.", file=sys.stderr)
    print(
        "".join(
            difflib.unified_diff(
                committed,
                generated,
                fromfile=str(committed_path),
                tofile=str(generated_path),
                n=3,
            )
        ),
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
