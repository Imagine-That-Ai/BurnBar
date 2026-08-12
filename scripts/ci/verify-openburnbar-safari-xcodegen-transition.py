#!/usr/bin/env python3
"""Verify the one permitted XcodeGen source-membership transition.

The Safari certification successor adds exactly two daemon sources and two
daemon-test sources to a project that was previously generated without those
untracked files. This verifier compares target source memberships by semantic
file reference instead of PBX object identifier, strips only the four audited
PBX file/build objects and their exact references, and then applies the
repository's full semantic PBX normalizer. It therefore fails closed on both
unexpected source membership and any unrelated target, build-setting, phase,
package, resource, or project-graph drift.
"""

from __future__ import annotations

import collections
import dataclasses
import importlib.util
import re
import sys
import tempfile
from pathlib import Path


PBX_ID_PATTERN = r"[A-F0-9]{24}"
OBJECTS_DECL = re.compile(r"\bobjects\s*=\s*\{")
OBJECT_ENTRY = re.compile(
    rf'\s*"?(?P<id>{PBX_ID_PATTERN})"?(?:\s*/\*\s*(?P<comment>.*?)\s*\*/)?\s*=\s*\{{',
    re.DOTALL,
)
ISA = re.compile(r"\bisa\s*=\s*(?P<isa>[A-Za-z0-9_]+)\s*;")

EXPECTED_BASE_COUNTS = {
    "OpenBurnBarDaemon": 230,
    "OpenBurnBarDaemonTests": 119,
}
EXPECTED_ADDITIONS = {
    "OpenBurnBarDaemon": collections.Counter(
        {
            "GatewayRequestAttribution.swift": 1,
            "SafariHandoffProcessSupervisor.swift": 1,
        }
    ),
    "OpenBurnBarDaemonTests": collections.Counter(
        {
            "SafariHandoffProcessSupervisorTests.swift": 1,
            "SafariHandoffProcessWatchdogTests.swift": 1,
        }
    ),
}


@dataclasses.dataclass(frozen=True)
class PBXObject:
    identifier: str
    comment: str
    body: str
    entry_start: int
    entry_end: int
    body_start: int
    body_end: int


@dataclasses.dataclass(frozen=True)
class SourceMembership:
    build_file_identifier: str
    file_reference_identifier: str


@dataclasses.dataclass(frozen=True)
class ProjectMemberships:
    objects: dict[str, PBXObject]
    by_target: dict[str, collections.Counter[str]]
    source_phases: dict[str, str]
    entries: dict[str, dict[str, list[SourceMembership]]]


def fail(message: str) -> None:
    raise ValueError(message)


def find_matching_brace(text: str, opening_brace: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening_brace, len(text)):
        character = text[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return index
    fail("unbalanced braces in project.pbxproj")


def parse_objects(text: str) -> dict[str, PBXObject]:
    declaration = OBJECTS_DECL.search(text)
    if declaration is None:
        fail("objects dictionary not found in project.pbxproj")
    opening_brace = text.find("{", declaration.start())
    closing_brace = find_matching_brace(text, opening_brace)
    body = text[opening_brace + 1 : closing_brace]
    objects: dict[str, PBXObject] = {}
    offset = 0
    while offset < len(body):
        match = OBJECT_ENTRY.match(body, offset)
        if match is None:
            offset += 1
            continue
        object_open = opening_brace + 1 + match.end() - 1
        object_close = find_matching_brace(text, object_open)
        identifier = match.group("id")
        if identifier in objects:
            fail(f"duplicate PBX object identifier {identifier}")
        identifier_offset = match.start("id")
        preceding_newline = body.rfind("\n", 0, identifier_offset)
        entry_start = opening_brace + 1 + preceding_newline + 1
        entry_end = object_close + 1
        while entry_end < len(text) and text[entry_end] in " \t":
            entry_end += 1
        if entry_end >= len(text) or text[entry_end] != ";":
            fail(f"PBX object {identifier} is missing its terminating semicolon")
        entry_end += 1
        if entry_end < len(text) and text[entry_end] == "\r":
            entry_end += 1
        if entry_end < len(text) and text[entry_end] == "\n":
            entry_end += 1
        objects[identifier] = PBXObject(
            identifier=identifier,
            comment=(match.group("comment") or "").strip(),
            body=text[object_open + 1 : object_close],
            entry_start=entry_start,
            entry_end=entry_end,
            body_start=object_open + 1,
            body_end=object_close,
        )
        offset = object_close - opening_brace
    if not objects:
        fail("no PBX objects parsed from project.pbxproj")
    return objects


def object_isa(pbx_object: PBXObject) -> str:
    match = ISA.search(pbx_object.body)
    return match.group("isa") if match else ""


def scalar(body: str, key: str) -> str | None:
    match = re.search(
        rf"(?m)^[ \t]*{re.escape(key)}[ \t]*=[ \t]*(?P<value>\"(?:\\.|[^\"])*\"|[^;]+);",
        body,
    )
    if match is None:
        return None
    value = match.group("value").strip()
    if value.startswith('"') and value.endswith('"'):
        value = bytes(value[1:-1], "utf-8").decode("unicode_escape")
    return value


def list_identifiers(body: str, key: str) -> list[str]:
    match = re.search(
        rf"\b{re.escape(key)}\s*=\s*\((?P<items>.*?)\);",
        body,
        re.DOTALL,
    )
    if match is None:
        fail(f"PBX object is missing {key} list")
    return re.findall(rf"\b{PBX_ID_PATTERN}\b", match.group("items"))


def require_object(
    objects: dict[str, PBXObject],
    identifier: str,
    expected_isa: str,
) -> PBXObject:
    pbx_object = objects.get(identifier)
    if pbx_object is None:
        fail(f"PBX object {identifier} is referenced but missing")
    actual_isa = object_isa(pbx_object)
    if actual_isa != expected_isa:
        fail(
            f"PBX object {identifier} must be {expected_isa}; "
            f"found {actual_isa or 'unknown'}"
        )
    return pbx_object


def file_reference_label(file_reference: PBXObject) -> str:
    path = scalar(file_reference.body, "path")
    name = scalar(file_reference.body, "name")
    label = path or name or file_reference.comment
    if not label:
        fail(f"PBXFileReference {file_reference.identifier} has no semantic label")
    normalized = label.replace("\\", "/").rstrip("/")
    basename = normalized.rsplit("/", 1)[-1]
    if not basename or basename in {".", ".."}:
        fail(
            f"PBXFileReference {file_reference.identifier} has unsafe label "
            f"{label!r}"
        )
    return basename


def source_memberships(path: Path) -> ProjectMemberships:
    if not path.is_file() or path.is_symlink():
        fail(f"project.pbxproj must be a real file: {path}")
    objects = parse_objects(path.read_text(encoding="utf-8", errors="strict"))
    target_memberships: dict[str, collections.Counter[str]] = {}
    source_phases: dict[str, str] = {}
    entries: dict[str, dict[str, list[SourceMembership]]] = {}

    for pbx_object in objects.values():
        if object_isa(pbx_object) != "PBXNativeTarget":
            continue
        target_name = scalar(pbx_object.body, "name") or pbx_object.comment
        if not target_name:
            fail(f"PBXNativeTarget {pbx_object.identifier} has no name")
        if target_name in target_memberships:
            fail(f"duplicate PBXNativeTarget name {target_name!r}")

        source_phase_ids: list[str] = []
        for phase_id in list_identifiers(pbx_object.body, "buildPhases"):
            phase = objects.get(phase_id)
            if phase is not None and object_isa(phase) == "PBXSourcesBuildPhase":
                source_phase_ids.append(phase_id)
        if len(source_phase_ids) != 1:
            fail(
                f"target {target_name!r} must have exactly one Sources build "
                f"phase; found {len(source_phase_ids)}"
            )

        source_phase = require_object(
            objects,
            source_phase_ids[0],
            "PBXSourcesBuildPhase",
        )
        source_phases[target_name] = source_phase.identifier
        membership: collections.Counter[str] = collections.Counter()
        target_entries: dict[str, list[SourceMembership]] = collections.defaultdict(list)
        for build_file_id in list_identifiers(source_phase.body, "files"):
            build_file = require_object(objects, build_file_id, "PBXBuildFile")
            file_reference_id = scalar(build_file.body, "fileRef")
            if file_reference_id is None:
                fail(f"PBXBuildFile {build_file_id} has no fileRef")
            file_reference_id = file_reference_id.split()[0]
            if not re.fullmatch(PBX_ID_PATTERN, file_reference_id):
                fail(
                    f"PBXBuildFile {build_file_id} has malformed fileRef "
                    f"{file_reference_id!r}"
                )
            file_reference = require_object(
                objects,
                file_reference_id,
                "PBXFileReference",
            )
            label = file_reference_label(file_reference)
            membership[label] += 1
            target_entries[label].append(
                SourceMembership(
                    build_file_identifier=build_file.identifier,
                    file_reference_identifier=file_reference.identifier,
                )
            )
        target_memberships[target_name] = membership
        entries[target_name] = dict(target_entries)

    if not target_memberships:
        fail("no native-target source memberships found in project.pbxproj")
    return ProjectMemberships(
        objects=objects,
        by_target=target_memberships,
        source_phases=source_phases,
        entries=entries,
    )


def render(counter: collections.Counter[str]) -> str:
    values: list[str] = []
    for name, count in sorted(counter.items()):
        values.append(name if count == 1 else f"{name} x{count}")
    return ", ".join(values) if values else "none"


def replace_spans(text: str, replacements: list[tuple[int, int, str]]) -> str:
    result = text
    last_start = len(text) + 1
    for start, end, replacement in sorted(replacements, reverse=True):
        if start < 0 or end < start or end > len(text):
            fail(f"invalid PBX replacement span {start}:{end}")
        if end > last_start:
            fail("overlapping PBX replacement spans")
        result = result[:start] + replacement + result[end:]
        last_start = start
    return result


def remove_reference_lines(
    pbx_object: PBXObject,
    identifiers: set[str],
) -> str:
    filtered: list[str] = []
    removed: set[str] = set()
    for line in pbx_object.body.splitlines(keepends=True):
        matching = {
            identifier
            for identifier in identifiers
            if re.search(rf"\b{re.escape(identifier)}\b", line)
        }
        if matching:
            removed.update(matching)
        else:
            filtered.append(line)
    missing = identifiers - removed
    if missing:
        fail(
            f"PBX object {pbx_object.identifier} did not contain expected "
            f"reference(s) {sorted(missing)}"
        )
    return "".join(filtered)


def stripped_generated_project(
    text: str,
    generated: ProjectMemberships,
) -> str:
    removal_object_ids: set[str] = set()
    phase_removals: dict[str, set[str]] = collections.defaultdict(set)
    file_reference_ids: set[str] = set()
    for target, additions in EXPECTED_ADDITIONS.items():
        phase_id = generated.source_phases[target]
        for source, expected_count in additions.items():
            memberships = generated.entries[target].get(source, [])
            if len(memberships) != expected_count:
                fail(
                    f"generated {target} source identity for {source} is "
                    f"ambiguous: found {len(memberships)}"
                )
            for membership in memberships:
                removal_object_ids.add(membership.build_file_identifier)
                removal_object_ids.add(membership.file_reference_identifier)
                phase_removals[phase_id].add(membership.build_file_identifier)
                file_reference_ids.add(membership.file_reference_identifier)

    build_references: collections.Counter[str] = collections.Counter()
    group_references: collections.Counter[str] = collections.Counter()
    replacements: list[tuple[int, int, str]] = []
    for pbx_object in generated.objects.values():
        if pbx_object.identifier in removal_object_ids:
            replacements.append(
                (pbx_object.entry_start, pbx_object.entry_end, "")
            )
            continue

        referenced = {
            identifier
            for identifier in removal_object_ids
            if re.search(
                rf"\b{re.escape(identifier)}\b",
                pbx_object.body,
            )
        }
        if not referenced:
            continue

        isa = object_isa(pbx_object)
        allowed: set[str] = set()
        if isa == "PBXSourcesBuildPhase":
            allowed = phase_removals.get(pbx_object.identifier, set())
            build_references.update(referenced & allowed)
        elif isa in {"PBXGroup", "PBXVariantGroup"}:
            allowed = referenced & file_reference_ids
            group_references.update(allowed)
        unexpected = referenced - allowed
        if unexpected:
            fail(
                f"audited Safari PBX object(s) {sorted(unexpected)} are "
                f"referenced from unexpected {isa or 'unknown'} object "
                f"{pbx_object.identifier}"
            )
        replacements.append(
            (
                pbx_object.body_start,
                pbx_object.body_end,
                remove_reference_lines(pbx_object, allowed),
            )
        )

    for phase_id, build_ids in phase_removals.items():
        for build_id in build_ids:
            if build_references[build_id] != 1:
                fail(
                    f"audited PBXBuildFile {build_id} must appear exactly once "
                    f"in source phase {phase_id}; found {build_references[build_id]}"
                )
    for file_reference_id in file_reference_ids:
        if group_references[file_reference_id] != 1:
            fail(
                f"audited PBXFileReference {file_reference_id} must appear "
                "exactly once in a project group; found "
                f"{group_references[file_reference_id]}"
            )

    stripped = replace_spans(text, replacements)
    for identifier in removal_object_ids:
        if re.search(rf"\b{re.escape(identifier)}\b", stripped):
            fail(f"audited PBX identifier {identifier} remains after stripping")
    return stripped


def canonicalizer_module():
    verifier = Path(__file__).with_name("verify-xcodegen-pbxproj-drift.py")
    if not verifier.is_file() or verifier.is_symlink():
        fail(f"semantic PBX verifier is missing or symlinked: {verifier}")
    spec = importlib.util.spec_from_file_location(
        "openburnbar_xcodegen_semantic_verifier",
        verifier,
    )
    if spec is None or spec.loader is None:
        fail(f"could not load semantic PBX verifier: {verifier}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def require_no_other_semantic_drift(
    before: Path,
    after: Path,
    generated: ProjectMemberships,
) -> None:
    original_text = before.read_text(encoding="utf-8", errors="strict")
    generated_text = after.read_text(encoding="utf-8", errors="strict")
    stripped_text = stripped_generated_project(generated_text, generated)
    canonicalizer = canonicalizer_module()
    with tempfile.TemporaryDirectory(
        prefix="openburnbar-safari-xcodegen-transition."
    ) as temporary_directory:
        stripped_path = Path(temporary_directory) / "stripped.pbxproj"
        stripped_path.write_text(stripped_text, encoding="utf-8")
        original_canonical = canonicalizer.canonical_pbxproj(before)
        stripped_canonical = canonicalizer.canonical_pbxproj(stripped_path)
    if original_canonical != stripped_canonical:
        fail(
            "generated project contains semantic drift outside the four "
            "audited Safari source memberships"
        )


def verify_transition(before: Path, after: Path) -> None:
    original = source_memberships(before)
    generated = source_memberships(after)
    if set(original.by_target) != set(generated.by_target):
        added_targets = sorted(set(generated.by_target) - set(original.by_target))
        removed_targets = sorted(set(original.by_target) - set(generated.by_target))
        fail(
            "native target set changed; "
            f"added={added_targets or 'none'}, removed={removed_targets or 'none'}"
        )

    for target, expected_count in EXPECTED_BASE_COUNTS.items():
        actual_count = original.by_target.get(target)
        if actual_count is None:
            fail(f"required target {target!r} is missing from the original project")
        if sum(actual_count.values()) != expected_count:
            fail(
                f"original {target} Sources count must be {expected_count}; "
                f"found {sum(actual_count.values())}"
            )

    changed_targets: set[str] = set()
    for target in sorted(original.by_target):
        removed = original.by_target[target] - generated.by_target[target]
        added = generated.by_target[target] - original.by_target[target]
        if not removed and not added:
            continue
        changed_targets.add(target)
        expected_added = EXPECTED_ADDITIONS.get(target, collections.Counter())
        if removed:
            fail(
                f"{target} removed source membership that is not permitted: "
                f"{render(removed)}"
            )
        if added != expected_added:
            fail(
                f"{target} source additions must be exactly "
                f"{render(expected_added)}; found {render(added)}"
            )

    if changed_targets != set(EXPECTED_ADDITIONS):
        fail(
            "changed source targets must be exactly "
            f"{sorted(EXPECTED_ADDITIONS)}; found {sorted(changed_targets)}"
        )

    for target, additions in EXPECTED_ADDITIONS.items():
        expected_generated_count = EXPECTED_BASE_COUNTS[target] + sum(additions.values())
        actual_generated_count = sum(generated.by_target[target].values())
        if actual_generated_count != expected_generated_count:
            fail(
                f"generated {target} Sources count must be "
                f"{expected_generated_count}; found {actual_generated_count}"
            )
        for source, expected_occurrences in additions.items():
            original_occurrences = original.by_target[target][source]
            generated_occurrences = generated.by_target[target][source]
            if original_occurrences != 0:
                fail(
                    f"original {target} unexpectedly already contains "
                    f"{source} x{original_occurrences}"
                )
            if generated_occurrences != expected_occurrences:
                fail(
                    f"generated {target} must contain {source} exactly "
                    f"{expected_occurrences} time(s); found {generated_occurrences}"
                )
    require_no_other_semantic_drift(before, after, generated)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "usage: verify-openburnbar-safari-xcodegen-transition.py "
            "<original.pbxproj> <generated.pbxproj>",
            file=sys.stderr,
        )
        return 64
    try:
        verify_transition(Path(argv[1]), Path(argv[2]))
    except (OSError, UnicodeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: XcodeGen changed only OpenBurnBarDaemon 230->232 and "
        "OpenBurnBarDaemonTests 119->121 with the four audited Safari sources."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
