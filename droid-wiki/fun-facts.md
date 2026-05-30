# Fun facts

Data collected 2026-05-30.

---

## 1. The entire codebase has exactly 2 TODO comments

```
grep -r "TODO\|FIXME\|HACK" AgentLens/ --include="*.swift" | wc -l
→ 2
```

Most production codebases in this size range carry dozens or hundreds of deferred notes. OpenBurnBar carries two. Whether this reflects exceptional discipline or aggressive deferred-comment cleanup by the factory-droid bot is left as an exercise.

---

## 2. The largest production Swift file is 4,589 lines of Hermes connection management

```
find AgentLens OpenBurnBarDaemon OpenBurnBarCore OpenBurnBarMobile -name "*.swift" \
  -exec wc -l {} + | sort -rn | head -5
```

| Lines | File |
|-------|------|
| 5,605 | `OpenBurnBarDaemon/Tests/.../OpenBurnBarMissionControlServiceTests.swift` |
| 4,744 | `OpenBurnBarDaemon/Tests/.../OpenBurnBarHTTPGatewayServerTests.swift` |
| 4,589 | `OpenBurnBarMobile/Services/HermesService.swift` |
| 4,383 | `AgentLens/Views/Dashboard/ProjectsView.swift` |
| 4,317 | `OpenBurnBarMobile/Views/Media/ScreenShareViewerView.swift` |

The top two are test files. The largest test file (`OpenBurnBarMissionControlServiceTests.swift`) is longer than most entire side-project codebases. Among production source, `HermesService.swift` owns Hermes relay connections, iroh transport, mission dispatch, and media session state — all in one 4,589-line file.

---

## 3. There are 17 log-format parsers in a single directory

```
ls AgentLens/Services/LogParser/*.swift | wc -l
→ 17
```

The parsers range from simple newline-delimited JSONL (Kimi, Warp) to complex multi-table SQLite readers (Goose via `GooseParser.swift`) to streaming subprocess output (Hermes). Providers covered include Claude Code, Factory Droid, Codex, Cursor Agent, Gemini CLI, Antigravity, Augment, Cline, Forge Dev, Grok Build, Kimi, Warp, Windsurf, and Hermes. `UsageAggregatorParsers.swift` (2,211 lines) stitches all of them together into the unified usage pipeline.

---

## 4. factory-droid[bot] co-authored 27% of the entire public commit history

```
git log origin/main --format="%B" | grep -c "Co-authored-by: factory-droid\[bot\]"
→ 232 out of 855 total commits
```

232 commits carry a `Co-authored-by: factory-droid[bot]` trailer. That covers the account-switcher, token-accounting precedence guards, indexing efficiency harness, and much of the SOTA hardening pass. The bot did not write the architecture — it shipped features inside it.
