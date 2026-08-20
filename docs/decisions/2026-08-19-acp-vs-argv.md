# ACP vs argv (2026-08-19)

Measured on Alberto’s Mac. No TBDs.

## Binaries

| id | path | version | protocol | launch argv | resume | permission | refused flags |
|----|------|---------|----------|-------------|--------|------------|---------------|
| grok | `/Users/albertonunez/.grok/bin/grok` → `grok-1.0.5-macos-aarch64` | `grok 1.0.5 (5115b46bc909) [stable]` | **ACP** (`grok agent stdio`). `initialize` + `notifications/initialized` + `session/new` round-tripped. `agentCapabilities.loadSession=true`, `sessionCapabilities` list/resume/close. `streaming-json` is “NDJSON of the agent native ACP session updates”. | `grok -p/--single <PROMPT> --output-format streaming-json`. `--help` **does** list `--prompt-file`. Do not pass `--always-approve` or `--permission-mode auto\|dontAsk\|bypassPermissions`. | `--resume` / `-c --continue`. ACP `session/load` advertised. | ACP `session/request_permission` (client method). Default permission-mode `default`. | `--always-approve`; `--permission-mode auto`, `dontAsk`, `bypassPermissions`; slash command `/always-approve` |
| kimi-code | `/Users/albertonunez/.kimi-code/bin/kimi` | `0.36.1` (`agentInfo.name=Kimi Code CLI`) | **ACP** (`kimi acp`). `initialize` + `session/new` returned `sessionId`. Modes include `default` (manual), `plan`, `auto`, `yolo`. | `kimi -p/--prompt` is non-interactive. Moonshot `-p` auto-approves regular tools — **incompatible** if the daemon owns approvals unless tools are disabled. | `-S/--session`, `-c/--continue`. ACP session resume/load advertised. | ACP default mode “Manual approvals; tools execute normally.” Refuse `session/set_mode` into `auto` or `yolo`. | `-y/--yolo`; `--auto`; leftover `kimi-cli --yolo/--afk/--print` auto-approve |
| kimi-cli (leftover) | `/Users/albertonunez/.local/bin/kimi-cli` | (help only; not launched) | argv leftover. Not the product binary. | `-p` prompt; `--print` auto-approves tools. | `-S/--session`, `-C/--continue` | auto-approve in print/afk/yolo | `--yolo`, `--afk`, `--print` |
| gemini (leftover) | `/Users/albertonunez/.local/bin/gemini` | `0.50.0` | `--acp` / `--experimental-acp` exist in `--help`. **initialize produced no stdout in 8s** — not a launch path. | `-p/--prompt` **requires the prompt text**. | `--resume`, `--session-id` | `--approval-mode default`. | `-y/--yolo`; `--approval-mode yolo` |
| antigravity | `/Users/albertonunez/.local/bin/agy` | `1.1.15` | **argv**. `--help` has no ACP/stdio. | `agy -p/--print/--prompt` with prompt text. | `--continue` / `-c`, `--conversation` | default prompts. | `--dangerously-skip-permissions`; `--mode accept-edits` is edit-auto, not used for daemon-owned approvals |

### `--help` excerpts (measured)

**grok 1.0.5**

```
      --always-approve
          Auto-approve all tool executions
      --output-format <OUTPUT_FORMAT>
          [possible values: plain, json, streaming-json, streaming-messages-json]
  -p, --single <PROMPT>
          Single-turn prompt. Prints the response to stdout and exits
      --permission-mode <MODE>
          [possible values: default, acceptEdits, auto, dontAsk, bypassPermissions, plan]
      --prompt-file <PATH>
          Single-turn prompt from a file
  agent        Run Grok without the interactive UI
```

`grok agent stdio --help`: debug/debug-file/help/leader-socket only.

**kimi 0.36.1**

```
  -y, --yolo                    Auto-approve regular tool calls
  --auto                        Start in auto permission mode
  -p, --prompt <prompt>         Run one prompt non-interactively
  acp [options]                 Run kimi-code as an Agent Client Protocol (ACP) server over stdio.
```

**gemini 0.50.0**

```
  -p, --prompt                    Run in non-interactive (headless) mode with the given prompt.
  -y, --yolo                      Automatically accept all actions
      --approval-mode             [choices: "default", "auto_edit", "yolo", "plan"]
      --acp                       Starts the agent in ACP mode
```

**agy 1.1.15**

```
  --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting
  -p                              Short alias for --print
  --print                         Run a single prompt non-interactively and print the response
```

## Verdict

- grok: **acp** (`grok agent stdio`)
- kimi-code: **acp** (`kimi acp`); argv `-p` incompatible with daemon-owned approvals
- gemini-or-agy: **argv** via **Antigravity (`agy`)** — leftover `gemini --acp` did not round-trip initialize

## Implications for PR-C

- One stdio JSON-RPC client: **yes** (grok + kimi). Map `session/request_permission` onto `respondMissionApproval` / Mac-signed pre-auth. Refuse `allow_always`, `yolo`, `auto`, `session/set_mode` auto-accept.
- Argv parsers still required for: **Antigravity (`agy -p`)** and any bonus catalog row that stays `launch: none` until measured.
- Official grok headless still has `--prompt-file` on 1.0.5; ACP is the launch path so resume must not emit `--prompt-file` unless staying on argv.
- Consumer Gemini CLI sunset 2026-06-18: default gemini → Antigravity. Do not launch leftover `gemini --acp` until initialize+session/new round-trips.

## Bonus backends (catalog rows, not extra PRs)

openclaw, openclaude, omp, forge, antigravity, junie, opencode, ollama remain catalog rows. `launch` stays `none` until a later ACP/argv measurement. Kimi `-p` auto-approve is a policy hole, not an argv spike.
