#!/usr/bin/env python3
"""Item 14 split: CLIAgentMissionDispatcher.swift -> single-responsibility files.

Pure line moves + 6 minimal visibility widenings (private -> internal) for
members now used across the split files. Verifies losslessness: every original
line lands verbatim in exactly one destination segment, except the 6 edited
declaration lines (verified individually) and the replicated import block /
3-line private String.nilIfEmpty helper.
"""

SRC = "OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift"
DIR = "OpenBurnBarMobile/Services/"

with open(SRC) as f:
    orig = f.read().split("\n")

def seg(a, b):
    return orig[a - 1 : b]

N = len(orig)
print(f"original physical lines: {N}")

def expect(lineno, prefix):
    got = orig[lineno - 1]
    assert got.strip().startswith(prefix), f"line {lineno}: expected {prefix!r}, got {got!r}"

expect(1, "import FirebaseAuth")
expect(7, "import os")
expect(9, "private let cliMissionSignalLogger")
expect(11, "private struct CLIAgentMissionPrivatePayload: Codable {")
expect(48, "private struct CLIAgentMissionEventPrivatePayload: Codable {")
expect(57, "private enum CLIAgentMissionCloudSealer {")
expect(220, "}")
expect(222, "@MainActor")
expect(223, "final class CLIAgentMissionDispatcher {")
expect(226, "private let firestoreProvider: () -> Firestore")
expect(232, "func dispatch(")
expect(491, "}")
expect(493, "// MARK: - Fan-out dispatch (Hermes Square §6.4)")
expect(836, "private static func selectedModelID(")
expect(944, "}")
expect(946, "// MARK: - Mission group observation")
expect(1137, "}")
expect(1139, "enum DispatchError: LocalizedError {")
expect(1163, "}")
expect(1164, "}")
expect(1166, "@MainActor")
expect(1167, "final class AgentHarnessImportJobDispatcher {")
expect(1262, "}")
expect(1264, "enum CLIAgentMissionRequestPayloadFactory {")
expect(1568, "}")
expect(1570, "final class CLIAgentMissionObservation {")
expect(1584, "}")
expect(1586, "struct CLIAgentMissionEvent: Equatable, Sendable, Identifiable {")
expect(1659, "struct CLIAgentMissionSnapshot: Equatable, Sendable, Identifiable {")
expect(1826, "}")
expect(1828, "private extension String {")
expect(1830, "}")

IMPORTS = seg(1, 7)
STREXT = seg(1828, 1830)

SPLIT_NOTE = [
    "Split out of `CLIAgentMissionDispatcher.swift` (audit wave 4, item 14",
    "structural decomposition). Pure move — no behavior change.",
]

def header(title, body=SPLIT_NOTE):
    return [f"// MARK: - {title}", "//"] + [f"// {line}".rstrip() for line in body] + [""]

EXT_OPEN = ["extension CLIAgentMissionDispatcher {"]
EXT_CLOSE = ["}"]

files = {}

# Root: imports, logger, class core (decl/init/dispatch/observe/fetch),
# DispatchError, String helper.
files[SRC] = (
    seg(1, 10)            # imports, blank, logger, blank
    + seg(222, 491)       # class decl .. fetchMissionSnapshot
    + [""]                # separator (orig line 492 / 1138 blank)
    + seg(1139, 1164)     # DispatchError + class closing brace
    + [""]
    + STREXT
)

files[DIR + "CLIAgentMissionDispatcher+Sealing.swift"] = (
    IMPORTS + [""] + header("CLI mission sealed-payload envelopes + cloud sealer")
    + seg(11, 220)
)

files[DIR + "CLIAgentMissionDispatcher+FanOut.swift"] = (
    IMPORTS + [""] + header("Fan-out dispatch, synthesis + model routing")
    + EXT_OPEN + seg(493, 944) + EXT_CLOSE
    + [""] + STREXT
)

files[DIR + "CLIAgentMissionDispatcher+MissionControl.swift"] = (
    IMPORTS + [""] + header("Mission group observation, merge, approval + cancel")
    + EXT_OPEN + seg(946, 1137) + EXT_CLOSE
)

files[DIR + "AgentHarnessImportJobDispatcher.swift"] = (
    IMPORTS + [""] + header("Agent harness import-job dispatcher")
    + seg(1166, 1262)
    + [""] + STREXT
)

files[DIR + "CLIAgentMissionRequestPayloadFactory.swift"] = (
    IMPORTS + [""] + header("CLI mission request payload factory")
    + seg(1264, 1568)
    + [""] + STREXT
)

files[DIR + "CLIAgentMissionModels.swift"] = (
    IMPORTS + [""] + header("CLI mission observation handle + snapshot/event models")
    + seg(1570, 1826)
    + [""] + STREXT
)

# ---- coverage verification (before edits) ----
covered = [0] * (N + 1)
segments = [
    (1, 10), (11, 220), (222, 491), (493, 944), (946, 1137), (1139, 1164),
    (1166, 1262), (1264, 1568), (1570, 1826), (1828, 1830),
]
for a, b in segments:
    for i in range(a, b + 1):
        covered[i] += 1
for i in range(1, N + 1):
    if covered[i] == 0:
        assert orig[i - 1].strip() == "", f"dropped non-blank line {i}: {orig[i-1]!r}"
    assert covered[i] <= 1, f"line {i} covered twice"

def contains_contiguous(hay, needle):
    return any(hay[i : i + len(needle)] == needle for i in range(len(hay) - len(needle) + 1))

checks = {
    SRC: [(1, 10), (222, 491), (1139, 1164), (1828, 1830)],
    DIR + "CLIAgentMissionDispatcher+Sealing.swift": [(11, 220)],
    DIR + "CLIAgentMissionDispatcher+FanOut.swift": [(493, 944), (1828, 1830)],
    DIR + "CLIAgentMissionDispatcher+MissionControl.swift": [(946, 1137)],
    DIR + "AgentHarnessImportJobDispatcher.swift": [(1166, 1262), (1828, 1830)],
    DIR + "CLIAgentMissionRequestPayloadFactory.swift": [(1264, 1568), (1828, 1830)],
    DIR + "CLIAgentMissionModels.swift": [(1570, 1826), (1828, 1830)],
}
for path, segs in checks.items():
    for a, b in segs:
        assert contains_contiguous(files[path], seg(a, b)), f"{path}: segment {a}-{b} not verbatim"

# ---- minimal visibility widenings (private -> internal), applied post-move ----
def edit(path, old, new):
    text = "\n".join(files[path])
    assert text.count(old) == 1, f"{path}: expected exactly 1 occurrence of {old!r}, got {text.count(old)}"
    files[path] = text.replace(old, new).split("\n")

# used by +Sealing / +FanOut files
edit(SRC,
     "private let cliMissionSignalLogger = Logger(",
     "let cliMissionSignalLogger = Logger(")
# used by root dispatch/observe/fetch AND +FanOut/+MissionControl extensions
edit(SRC,
     "    private let firestoreProvider: () -> Firestore",
     "    let firestoreProvider: () -> Firestore")
# used by dispatcher, factory, models files
edit(DIR + "CLIAgentMissionDispatcher+Sealing.swift",
     "private struct CLIAgentMissionPrivatePayload: Codable {",
     "struct CLIAgentMissionPrivatePayload: Codable {")
edit(DIR + "CLIAgentMissionDispatcher+Sealing.swift",
     "private struct CLIAgentMissionEventPrivatePayload: Codable {",
     "struct CLIAgentMissionEventPrivatePayload: Codable {")
edit(DIR + "CLIAgentMissionDispatcher+Sealing.swift",
     "private enum CLIAgentMissionCloudSealer {",
     "enum CLIAgentMissionCloudSealer {")
# called from root dispatch()
edit(DIR + "CLIAgentMissionDispatcher+FanOut.swift",
     "    private static func selectedModelID(",
     "    static func selectedModelID(")

for path, lines in files.items():
    with open(path, "w") as f:
        f.write("\n".join(lines).rstrip("\n") + "\n")
    print(f"wrote {path}: {len(lines)} lines")

print("LOSSLESSNESS OK: all", N, "original lines accounted for verbatim exactly once")
print("(6 declaration lines then widened private->internal; imports + nilIfEmpty helper replicated per file)")
