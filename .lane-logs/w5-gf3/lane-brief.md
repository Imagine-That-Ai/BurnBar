# Lane GF-W5-3: split OpenBurnBarMobile/Views/Navigation/AuroraNavigationIcons.swift (1842 lines)

You are a mechanical refactoring lane. Your ONLY job is a **pure-move split** of one god file. No behavior changes, no renames, no "improvements", no reformatting of moved code.

## Task

Split `OpenBurnBarMobile/Views/Navigation/AuroraNavigationIcons.swift` into pieces of **≤800 lines** each, split **by icon**. The file contains the `AuroraNavDestination` enum plus six bespoke animated icon implementations (Pulse, Burn, Insights, Streams, Hermes, You).

- `AuroraNavigationIcons.swift` keeps the `AuroraNavDestination` enum, shared helpers, and the file-header design-rules comment block.
- Move each icon's shapes/views (all `Shape`/`View` types belonging to one glyph, including their `animatableData` plumbing) into `AuroraNavIcon+<Name>.swift` in the SAME directory (e.g. `AuroraNavIcon+Pulse.swift`, `AuroraNavIcon+Burn.swift`, `AuroraNavIcon+Streams.swift`, `AuroraNavIcon+Hermes.swift`, `AuroraNavIcon+You.swift`, `AuroraNavIcon+Insights.swift`). Group two small icons in one file only if each resulting file stays cohesive; NEVER exceed 800 lines.
- Every moved declaration keeps its exact source text. Access levels: if a `private` member is used across the new file boundary, change it to the minimum that compiles (`internal`) and add `// pure-move: was private` on the same line. Make NO other edits.
- New file basenames must be UNIQUE across the whole repo (CI gate). Check with:
  `git ls-files '*.swift' | xargs -n1 basename | sort | uniq -d` (must print nothing new).

## After moving

1. Run `xcodegen generate --spec project.yml` at the repo root (this file is in the OpenBurnBarMobile app target; the pbxproj must be regenerated).
2. Parse-check every touched file:
   `xcrun swiftc -parse <file>` for each new/modified swift file (parse errors = fix the split, not the code).
3. Losslessness proof → write into `.lane-logs/w5-gf3/`:
   - `git show HEAD:OpenBurnBarMobile/Views/Navigation/AuroraNavigationIcons.swift > .lane-logs/w5-gf3/original.swift`
   - Concatenate the primary file + all new pieces (in a documented order) to `.lane-logs/w5-gf3/reconstructed.swift`.
   - Normalize BOTH sides identically (strip lines that are only: `import ...`, `// MARK:` headers you added, blank lines) into `original.norm` and `reconstructed.norm`, write the exact normalization script you used to `.lane-logs/w5-gf3/normalize.sh`, then `diff original.norm reconstructed.norm > losslessness.diff` (must be empty) and record `shasum -a 256` of both norm files in `losslessness.sha256`.
4. Line-count proof: `wc -l` of every resulting piece into `.lane-logs/w5-gf3/linecounts.txt` — every piece ≤800. A 900-line "piece" is a FAILED lane.

## Hard rules

- Do NOT commit. Do NOT push. Do NOT run any `git commit/push/config` command. A reviewer commits after inspecting your diff.
- Do NOT touch any file other than: the split target, the new pieces, project.yml-generated `OpenBurnBar.xcodeproj/project.pbxproj`, and `.lane-logs/w5-gf3/`.
- Do NOT resolve merge conflicts, edit firestore rules, or touch entitlement/budget logic.

When everything above is done and verified, print exactly: `LANE READY FOR REVIEW w5-gf3` followed by a one-paragraph summary listing the new files and their line counts.
