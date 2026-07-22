# The Ministry

The Ministry is the local MCP orchestration layer for fan-out droid workers. It lives in `tools/openburnbar-mcp` and exposes `ministry_*` tools from the `openburnbar-local` server. It does not modify the Swift router, Elder Wand/fusion ids, Firestore, or crypto paths.

The dispatch-to-claim authority rules, persistence map, and explicit separation
from Elder fusion are documented in
[Elder Wand and Pareto Wand contracts](ELDER_AND_PARETO_WAND_CONTRACTS.md).

## Tools

| Tool | Purpose |
|---|---|
| `ministry_list_wands` | Read `wands.v1.json`, or return the in-memory Council/Pareto seed when absent. |
| `ministry_validate_wands` | Sanitize the wand store without writing it. |
| `ministry_save_wands` | Operator-gated write of sanitized wands using atomic replace. |
| `ministry_list_launchable` | Build the droid launch universe from `~/.factory/settings.json` `customModels[]` plus a small built-in allowlist. |
| `ministry_provider_quota` | Authenticated `GET /v1/models` against the local OpenBurnBar gateway. |
| `ministry_select_model_for_wand` | Rank candidates by wand policy, optionally smoke-probing until a model lands a commit. |
| `ministry_select_models_for_wand` | Select N candidates by wand policy, optionally requiring provider diversity and smoke-proven commits. |
| `ministry_smoke_probe` | Disposable temp-repo `droid exec` probe at the wand autonomy level. |
| `ministry_build_droid_command` | Return a `droid exec` command with namespaced disabled tools, JSON output, and `result.done`. |
| `ministry_collect_result` | Classify worker completion by done marker, `is_error`, and HEAD-vs-base SHA. |
| `ministry_cleanup_plan` | Emit cleanup commands after the diff and result have been captured, including only exact transcript filename candidates. |

`ministry_smoke_probe` and proven selection use the existing `spawn_process` MCP capability gate. `ministry_save_wands` uses the existing `local_write` gate.

## Wand Store

Default location:

```text
_default_db_path().parent/ministry/wands.v1.json
```

If the file is absent or corrupt, the MCP returns an in-memory seed:

- Council Wand: `selector=best`, `autonomy=high`, `minCapabilityRank=10`, `allowBackends=["builtin","direct"]`
- Pareto Wand: `selector=pareto`, `autonomy=medium`, `minCapabilityRank=10`, `allowBackends=["builtin","direct"]`

Gateway candidates remain visible in `ministry_list_launchable`, but the seed wands avoid the local gateway by default because the current high-rank Claude gateway routes are TUI-bridged rather than headless. Save a custom wand with `allowBackends` including `"gateway"` when gateway launch routing is intentionally being tested.

The sanitizer rejects non-object entries, duplicate ids, empty names, invalid selectors, invalid autonomy values, and malformed backend lists. It guarantees exactly one default wand.

## Selection

Candidates come from Factory `customModels[]` plus the built-in allowlist. The catalog join uses:

1. exact model id
2. exact alias
3. provider-scoped matchers

`catalog.json` is read from:

```text
OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json
```

`models.json` is read from `website/public/data/models.json` first, then `website/scripts/rundown-seed/models.json`. It is indexed by `modelID` and aliases with dot/dash normalization.

Pareto ranking demotes absent or zero-price catalog rows when there is no `costSignal`, so an unknown-cost model cannot beat a real-priced capable model by looking free.

Proof mode starts with launch slugs that are already known to be headless-capable in this local universe, then falls back to policy-ranked custom routes. Normal unproven selection still uses the wand policy rank. The current catalog does not have a first-class GLM-5.2 rank row, so the verified Z.ai direct `glm-5.2` slug carries a rank-20 fallback. That fallback does not inherit GLM-5 catalog pricing or identity unless an exact catalog row or alias is added.

## Command Contract

`ministry_build_droid_command` returns:

- `prompt`: content the orchestrator should write to `promptPath`
- `command`: shell command to launch the worker
- `resultPath`: JSON output path
- `donePath`: completion marker path

The command uses the namespaced disabled-tool ids required by droid, for example:

```text
mem0-mcp___add_memory,mem0-lahormigadormida___add_memory,serena___search_for_pattern
```

The command shape is:

```bash
droid exec --auto <level> -m <model> --disabled-tools <namespaced_ids> -f <promptPath> -o json > <resultPath>; rc=$?; printf ... > <donePath>; exit $rc
```

Do not classify a worker by `resultPath` size. The redirected result file can remain size zero while droid is still running. Treat the worker as complete only after `donePath` exists.

## Fan-Out Runbook

1. Select and prove the worker set:

```text
ministry_select_models_for_wand(
  wand_id="council",
  count=2,
  require_provider_diversity=true,
  prove_headless=true,
  max_probes=4
)
```

2. For each worker:

```bash
runid="$(date +%s)-$RANDOM"
agent="agent-1"
branch="ministry/$runid/$agent"
worktree="/private/tmp/bb-ministry-$runid-$agent"
git worktree add "$worktree" -b "$branch" HEAD
base_sha="$(git -C "$worktree" rev-parse HEAD)"
```

3. Build the worker command for each selected `modelArg` with `cwd=$worktree`, write the returned `prompt` to `promptPath`, then launch it in cmux/tmux.

4. Collect:

```text
ministry_collect_result(worktree_path, base_sha, resultPath, donePath)
```

Success means:

- `donePath` exists
- `resultPath` parses and `is_error` is false
- `git -C <worktree> rev-parse HEAD` differs from `base_sha`

5. Before cleanup, capture the diff, result JSON, done marker, and any relevant transcript id. Then use `ministry_cleanup_plan` and remove the worktree, branch, prompt/result/done files, and exact Factory session transcript candidates.

## Verification

Focused local tests:

```bash
cd tools/openburnbar-mcp
.venv/bin/python -m pytest tests/test_ministry.py
```

Full MCP Python suite:

```bash
cd tools/openburnbar-mcp
.venv/bin/python -m pytest tests
```

Live acceptance is an N=2 selector-to-spawn dry run: two workers selected through `ministry_select_models_for_wand(..., count=2, require_provider_diversity=true, prove_headless=true)`, launched with the generated command, and verified by `ministry_collect_result` as two landed commits on separate branches.
