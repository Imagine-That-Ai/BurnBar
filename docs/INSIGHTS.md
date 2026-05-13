# Insights

> A first-class destination on macOS, iPad, and iPhone that turns the data
> OpenBurnBar already collects — token usage, conversations, agent runs,
> provider quotas — into a **living, AI-authored analytics canvas**.

## What it is

Insights is OpenBurnBar's analytics workbench. You pick a model — Claude,
GPT-5, Hermes, Pi, Ollama, or the always-available local rule engine — and
it investigates, summarizes, and recommends across your AI-coding-agent
activity.

Each "canvas" is a persistent dashboard composed of typed widgets. The
canvas lives on disk (with optional cloud sync), survives app restarts, merges
imports by stable canvas ID, and exports cleanly to JSON, PNG, PDF, or
Markdown.

## Quick start

### macOS

1. Open OpenBurnBar and click the new **Insights** entry in the dashboard
   sidebar.
2. The first-run gallery is the **Today** template — a daily snapshot
   composed entirely from on-device data. Nothing has been sent anywhere.
3. To investigate, type a prompt in the composer at the bottom of the
   canvas and hit ⌘ Return. The model dropdown above the composer lets you
   pick which model authors the canvas.

### iPad

Same sidebar entry. Inspector lives in a sheet that you can pull up via
the slider icon. Widgets project to a 6-column layout — same intent as
macOS, projected to fit.

### iPhone

The Insights tab lives between Burn and Streams. Widgets stack
single-column. Long-press a canvas in the bottom-sheet library to reorder.

## Widget catalog

The renderer dispatch table accepts 26 widget kinds — full list in
`InsightWidgetKind`. Highlights:

| Kind                | What it shows                                              |
|---------------------|------------------------------------------------------------|
| `kpiTile`           | Big-number with delta + sparkline                          |
| `timeSeriesLine`    | Daily trend, optional per-provider/model breakdown         |
| `timeSeriesArea`    | Stacked area for cost mix                                  |
| `streamGraph`       | ThemeRiver for provider/model dynamics                     |
| `barRanking`        | Top-N agents / models / projects / files                   |
| `donut`             | Cost/token share                                           |
| `treemap`           | Spend by `(provider × model)`                              |
| `heatmap`           | Hour × day-of-week activity                                |
| `scatter`           | Cost-per-Mtoken × volume, etc.                             |
| `sankey`            | Flow from agent → model → project                          |
| `radar`             | Per-agent capability fingerprint                           |
| `cohort`            | Weekly retention by cohort                                 |
| `funnel`            | Stage-by-stage drop-off                                    |
| `quotaPulse`        | Live provider quota gauges                                 |
| `forecast`          | Holt-linear projection with uncertainty band               |
| `anomalyTable`      | Robust-z anomaly list                                      |
| `narrative`         | LLM-written paragraph + bullets + cite chips               |
| `recommendation`    | Suggested change + impact + confidence                     |
| `useCaseCluster`    | LLM-clustered conversation topics                          |
| `agentFocusMatrix`  | Per-agent × focus heat                                     |
| `modelFocusMatrix`  | Per-model × focus heat                                     |
| `drilldownList`     | Click-through session list                                 |
| `mermaid`           | Diagrams the LLM emits                                     |
| `ascii`             | TUI-style snapshots                                        |
| `composed`          | Recursive stack of any of the above                        |
| `error`             | Graceful "this widget failed to compute" card              |

## Built-in templates

Eight ready-to-go canvases ship with the app:

1. **Today** — daily snapshot.
2. **Cost Audit (7d)** — where the money went last week.
3. **Agent Focus** — what each agent is being used for.
4. **Model Focus** — where each model excels.
5. **Use-Case Library** — topic clusters + examples.
6. **Quota Health** — provider headroom.
7. **Quarterly Review** — 90 days at a glance.
8. **Anomalies** — outlier days, spikes, dips.

## Model picker

Available adapters:

- **Local rules** (default, on-device, $0)
- **Anthropic** (Claude Opus 4.7 / Sonnet 4.6 / Haiku 4.5; user's API key)
- **OpenAI** (GPT-5, GPT-5 mini; user's API key)
- **OpenRouter** (any model; user's API key)
- **Hermes** (your existing relay)
- **Pi** (local Pi runtime)
- **Ollama** (local)

The picker is sorted with `localOnly` first. Each chip shows an egress
tier badge so you always know where data is going.

## Privacy

Insights enforces a strict privacy contract on what may be sent to a
non-local model:

- No file contents, no source code.
- No conversation message bodies. (Only short, inferred titles.)
- No API keys, no credential labels.
- Device names hashed to `device_xxxx`.
- Project names hashed to `project_xxxx`. The displayName is the last
  path component only.
- The digest is capped at **24 KB** end-to-end (enforced by tests).

Toggle **Privacy mode** in the composer or in Settings → Insights to
restrict the model picker to `localOnly` adapters.

Every investigation writes to a local audit log
(`~/Library/Application Support/OpenBurnBar/Insights/audit.jsonl`) with
prompt, model, egress tier, byte count, and cost.

## Workspace controls (macOS)

- ⌘ Return — send the composer prompt to the selected model.
- **Refresh** (canvas header) — recompute every widget's data from the
  current snapshot. Widgets refresh in place and show their freshness pill.
- **Audit** (canvas header) — open the local audit table of every
  investigation that has touched your data, with model, egress tier,
  byte count, status, and cost per row. Includes a destructive **Clear**.
- **Inspector** (right rail) — edit the selected widget's title, time
  range, and layout (Column / Row / Width / Height steppers, clamped to
  the 12-column grid). Theme and canvas-level time window live at the
  top of the inspector.
- **Canvas library** (left rail) — switch between canvases, delete via
  context menu, or stamp a fresh canvas from **New from template**.

## Storage layout

```
~/Library/Application Support/OpenBurnBar/Insights/
├── canvases.json     — append-safe canvas history, merged by stable canvas ID
├── audit.jsonl       — investigation audit trail
└── cache/            — content-addressed canvas cache
```

## See also

- [`docs/INSIGHTS_ARCHITECTURE.md`](INSIGHTS_ARCHITECTURE.md) — internal
  architecture, gateway protocol, JSON-Schema contract, extension recipe.
- [`docs/CHART_STUDIO.md`](CHART_STUDIO.md) — the exploratory single-canvas
  surface; shares the same renderer grammar.
- [`docs/PRIVACY.md`](PRIVACY.md) — overall data-collection posture.
