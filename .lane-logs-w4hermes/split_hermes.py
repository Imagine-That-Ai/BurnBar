#!/usr/bin/env python3
"""Item 14 split: HermesGatewayAPI.swift -> single-responsibility files.

Pure line moves. Verifies losslessness: every original line is reproduced
verbatim in exactly one destination segment (plus the 3-line private
String.nilIfEmpty extension, which is duplicated per new file needing it,
matching the repo-wide per-file private-helper pattern).
"""
import sys

SRC = "OpenBurnBarMobile/Services/HermesGatewayAPI.swift"
DIR = "OpenBurnBarMobile/Services/"

with open(SRC) as f:
    orig = f.read().split("\n")
# orig is 0-based; helper for 1-based inclusive slices
def seg(a, b):
    return orig[a - 1 : b]

N = len(orig)
print(f"original physical lines: {N}")

# ---- boundary assertions (1-based) ----
def expect(lineno, prefix):
    got = orig[lineno - 1]
    assert got.strip().startswith(prefix), f"line {lineno}: expected {prefix!r}, got {got!r}"

expect(1, "import Foundation")
expect(7, "import OpenBurnBarCore")
expect(29, "final class HermesGatewayAPI")
expect(535, "}")
expect(537, "// MARK: - Callable response envelopes")
expect(553, "}")
expect(555, "// MARK: - Hermes Gateway Repository")
expect(558, "protocol HermesGatewayRepository")
expect(612, "extension HermesGatewayRepository {")
expect(674, "}")
expect(676, "// MARK: - Hermes Gateway Records")
expect(688, "private struct SealedGatewayPayload")
expect(694, "struct HermesGatewayMessageRecord")
expect(1104, "}")
expect(1106, "struct HermesGatewayClientRecord")
expect(1395, "extension HermesGatewayClientRecord {")
expect(1494, "struct HermesGatewayModelOptionRecord")
expect(1558, "struct HermesGatewayQueuedEvent")
expect(1562, "}")
expect(1568, "struct HermesGatewayApprovalRecord")
expect(1646, "extension HermesGatewayApprovalRecord {")
expect(1690, "}")
expect(1694, "struct HermesGatewayOpenedAttachment")
expect(1715, "struct HermesGatewayAttachmentRecord")
expect(1887, "struct HermesGatewayAttachmentManifest")
expect(1906, "}")
expect(1908, "enum HermesGatewayMessageResolver {")
expect(1980, "}")
expect(1982, "private extension String {")
expect(1984, "}")

IMPORTS = seg(1, 7)  # replicated import block (verbatim from source)
STREXT = seg(1982, 1984)

def header(title, body):
    return [
        f"// MARK: - {title}",
        "//",
    ] + [f"// {line}".rstrip() for line in body] + [""]

SPLIT_NOTE = [
    "Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural",
    "decomposition). Pure move — no behavior change.",
]

files = {}

# Root: class + private callable response envelopes (1..553), verbatim.
files[SRC] = seg(1, 553)

files[DIR + "HermesGatewayRepository.swift"] = (
    IMPORTS + [""] + header("HermesGatewayRepository protocol", SPLIT_NOTE)
    + seg(555, 674)
)

files[DIR + "HermesGatewayMessageRecord.swift"] = (
    IMPORTS + [""] + header("Hermes Gateway message records", SPLIT_NOTE)
    + seg(676, 1104) + [""] + seg(1908, 1980) + [""] + STREXT
)

files[DIR + "HermesGatewayClientRecord.swift"] = (
    IMPORTS + [""] + header("Hermes Gateway client records", SPLIT_NOTE)
    + seg(1106, 1562) + [""] + STREXT
)

files[DIR + "HermesGatewayApprovalRecord.swift"] = (
    IMPORTS + [""] + header("Hermes Gateway approval records", SPLIT_NOTE)
    + seg(1564, 1690) + [""] + STREXT
)

files[DIR + "HermesGatewayAttachmentRecord.swift"] = (
    IMPORTS + [""] + header("Hermes Gateway attachment records", SPLIT_NOTE)
    + seg(1692, 1906) + [""] + STREXT
)

# ---- losslessness verification ----
# Coverage map: each original line index must land in exactly one segment
# (imports + String extension are replicated by design; separator blank lines
# between top-level decls are absorbed).
covered = [0] * (N + 1)
segments = [
    (1, 553), (555, 674), (676, 1104), (1106, 1562), (1564, 1690),
    (1692, 1906), (1908, 1980), (1982, 1984),
]
for a, b in segments:
    for i in range(a, b + 1):
        covered[i] += 1
for i in range(1, N + 1):
    if covered[i] == 0:
        assert orig[i - 1].strip() == "", f"dropped non-blank line {i}: {orig[i-1]!r}"
    assert covered[i] <= 1, f"line {i} covered twice"

# Verify each output contains its segments verbatim & contiguous.
def contains_contiguous(hay, needle):
    for i in range(len(hay) - len(needle) + 1):
        if hay[i : i + len(needle)] == needle:
            return True
    return False

checks = {
    SRC: [(1, 553)],
    DIR + "HermesGatewayRepository.swift": [(555, 674)],
    DIR + "HermesGatewayMessageRecord.swift": [(676, 1104), (1908, 1980), (1982, 1984)],
    DIR + "HermesGatewayClientRecord.swift": [(1106, 1562), (1982, 1984)],
    DIR + "HermesGatewayApprovalRecord.swift": [(1564, 1690), (1982, 1984)],
    DIR + "HermesGatewayAttachmentRecord.swift": [(1692, 1906), (1982, 1984)],
}
for path, segs in checks.items():
    out = files[path]
    for a, b in segs:
        assert contains_contiguous(out, seg(a, b)), f"{path}: segment {a}-{b} not verbatim"
    # imports replicated verbatim
    assert out[:7] == IMPORTS or path == SRC

for path, lines in files.items():
    with open(path, "w") as f:
        f.write("\n".join(lines).rstrip("\n") + "\n")
    print(f"wrote {path}: {len(lines)} lines")

print("LOSSLESSNESS OK: all", N, "original lines accounted for (verbatim, exactly once; imports + nilIfEmpty helper replicated per file)")
