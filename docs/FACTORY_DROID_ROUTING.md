# Factory Droid Routing

Factory Droid is a routed subscription provider in OpenBurnBar, but it is not
presented as a direct OpenAI or Anthropic account. The daemon routes Factory
through the documented `droid exec` CLI surface and labels every advertised row
as Factory-served.

## Contract

- Factory Standard models (`gpt-*`, `claude-*`, `gemini-*`) route through the
  Factory Standard Usage lane only.
- Droid Core models (`glm-5.1`, `kimi-k2.6`, `deepseek-v4-pro`,
  `minimax-m2.7`, etc.) are separate Droid Core routes.
- Standard Usage exhaustion is treated as a same-model failover event. BurnBar
  may switch to another provider/account only when that route proves the same
  canonical model ID. It must never accept Factory's native
  Standard-to-Droid-Core downgrade as proof.
- Extra Usage is not used unless the user explicitly enables prepaid overage
  and has positive balance.
- For routed Standard accounts, the recommended Factory setting is **Ask me
  when I run out**. That makes exhaustion non-interactive and detectable by the
  daemon instead of silently changing the model class.

## Execution

The daemon runs Droid in non-interactive read-only mode:

```bash
droid exec --model <model> --output-format json --cwd <temporary-empty-dir> \
  --disabled-tools ApplyPatch,execute-cli -f <prompt-file>
```

The executor injects `FACTORY_API_KEY` into a sanitized process environment,
never passes `--auto`, never passes `--skip-permissions-unsafe`, redacts the key
from errors, and maps Factory limit/auth failures into normal provider-router
slot states.

## User-Facing Truth

`/v1/models` and Settings should say `Factory Droid` / `via Factory`. A request
for `gpt-5.5` can fail over to another Factory Max account's `gpt-5.5`, but it
must not become `glm-5.1`, `gpt-5.5-fast`, or a generic `openai:standard`
route. Exact model failover is keyed by canonical model ID, not provider family,
capability class, benchmark ranking, or Factory's own fallback lane.
