# Lane GF-W5-1: split AgentLens/Services/DataStore/UsageStore.swift (1798 lines)

You are a mechanical refactoring lane. Your ONLY job is a **pure-move split** of one god file. No behavior changes, no renames, no "improvements", no reformatting of moved code.

## Task

Split `AgentLens/Services/DataStore/UsageStore.swift` into pieces of **≤800 lines** each.

- Keep the primary type declaration in `UsageStore.swift`.
- Move cohesive member groups into extension files named `UsageStore+<Topic>.swift` in the SAME directory (e.g. `UsageStore+Queries.swift`, `UsageStore+Sync.swift` — pick topics from the existing `// MARK:` structure).
- Every moved declaration keeps its exact source text. Access levels: if a `private` member is used across the new file boundary, change it to the minimum that compiles (`internal`) and add `// pure-move: was private` on the same line. Make NO other edits.
- New file basenames must be UNIQUE across the whole repo (CI gate). Check with:
  `git ls-files '*.swift' | xargs -n1 basename | sort | uniq -d` (must print nothing new).

## After moving

1. Run `xcodegen generate --spec project.yml` at the repo root (this file is in the AgentLens app target; the pbxproj must be regenerated).
2. Parse-check every touched file:
   `xcrun swiftc -parse <file>` for each new/modified swift file (parse errors = fix the split, not the code).
3. Losslessness proof → write into `.lane-logs/w5-gf1/`:
   - `git show HEAD:AgentLens/Services/DataStore/UsageStore.swift > .lane-logs/w5-gf1/original.swift`
   - Concatenate the primary file + all new pieces (in a documented order) to `.lane-logs/w5-gf1/reconstructed.swift`.
   - Normalize BOTH sides identically (strip lines that are only: `import ...`, `// MARK:` headers you added, `extension UsageStore ... {` / closing `}` wrappers you added, blank lines) into `original.norm` and `reconstructed.norm`, write the exact normalization script you used to `.lane-logs/w5-gf1/normalize.sh`, then `diff original.norm reconstructed.norm > losslessness.diff` (must be empty) and record `shasum -a 256` of both norm files in `losslessness.sha256`.
4. Line-count proof: `wc -l` of every resulting piece into `.lane-logs/w5-gf1/linecounts.txt` — every piece ≤800. A 900-line "piece" is a FAILED lane.

## Hard rules

- Do NOT commit. Do NOT push. Do NOT run any `git commit/push/config` command. A reviewer commits after inspecting your diff.
- Do NOT touch any file other than: the split target, the new pieces, project.yml-generated `OpenBurnBar.xcodeproj/project.pbxproj`, and `.lane-logs/w5-gf1/`.
- Do NOT resolve merge conflicts, edit firestore rules, or touch entitlement/budget logic.

When everything above is done and verified, print exactly: `LANE READY FOR REVIEW w5-gf1` followed by a one-paragraph summary listing the new files and their line counts.
