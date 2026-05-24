# Hermes Skill Runs

Hermes Skill Runs are mobile-originated BurnBar missions that start from a
preview, dispatch to the trusted Mac, and stream back into iOS, iPadOS, and
Android Mission Console.

## Product Contract

- The default launch path is preview first, then run.
- Every run is a normal `cli_agent_mission_requests` document, so existing Mac
  claiming, approvals, cancellation, and event timelines still apply.
- Phones and tablets can follow the same timeline as the Mac writes events.
- Delivery is user-controlled per agent subscription:
  - `action_only`: approval prompts and terminal results only.
  - `full_stream`: every status, tool, artifact, and result event.
  - `muted`: no alerts; the timeline remains available in Mission Console.

## Follow-Along and PiP

iOS, iPadOS, and Android all receive Skill Run mission snapshots from the same
Firestore request and event stream. The companion apps surface that stream in
two ways:

- A floating Skill Run tile appears inside the app when the run is worth
  watching. `full_stream` opens it as soon as events arrive, `action_only`
  opens it for approvals or terminal results, and `muted` never opens it
  automatically.
- Dismissing the floating tile suppresses ordinary progress churn for that
  run, but a later approval request, action-required event, or terminal result
  resurfaces it.
- Picture in Picture is available from the floating tile and the mission detail
  sheet for Skill Run missions. Text-only Skill Runs render the current
  timeline/status into a PiP companion surface; Mercury and Agent Watch video
  PiP continue to use their existing media pipeline.

Approvals still happen in the app. PiP is a follow-along surface, not an
approval bypass: tapping back into BurnBar opens the mission detail sheet with
the normal Approve and Reject controls.

## Stable Skill IDs

| Skill | Wire ID | Primary value |
|---|---|---|
| What Happened? | `what_happened` | Explain a recent work window with evidence. |
| Burn Forensics | `burn_forensics` | Diagnose spend, quota, or provider spikes. |
| Pattern Miner | `pattern_miner` | Surface repeated workflow patterns. |
| Compare Agents | `compare_agents` | Compare runtime/provider behavior for a task. |
| Next Action Coach | `next_action_coach` | Convert session history into a next action. |
| Handoff Builder | `handoff_builder` | Create a resume-ready brief for another agent. |
| Regression Watch | `regression_watch` | Track recurring failures or behavior drift. |
| Run Pulse | `run_pulse` | Follow a live mission in short status pulses. |

## Firestore Fields

Mission request documents now accept:

- `sourceSkillID`
- `sourceSurface`
- `deliveryMode`
- `parentHermesThreadID`
- `schemaVersion: 3`

Mission event documents now accept:

- `sourceSkillID`
- `deliveryMode`
- `eventImportance`
- `skillStepID`

Subscription topic documents now accept:

- `deliveryMode`
- `minimumEventImportance`

These fields are optional for older clients, but new mobile surfaces should
write them so the companion apps can decide what to surface in real time.
