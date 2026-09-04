# Weekend public beta launch checklist

Owner playbook for a **Mac + iOS Core** soft launch. Goal is useful feedback, not virality.

Canonical copy lives in [`website/src/data/launch.ts`](../website/src/data/launch.ts) (`WEEKEND_PUBLIC_BETA_POSTS`).

## What you are launching

| In | Out (for this weekend) |
| --- | --- |
| Free local macOS DMG (`v1.0.29`) | Windows public CTA |
| iOS App Store companion | “Linux available everywhere” |
| Honest public-beta framing | Waiting for full platform parity |
| Feedback inbox + Discussions | Expecting Twitter alone to carry it |

**Success bar:** 25 installs · 10 replies · 5 detailed bug reports.

## T-24h / Friday prep

- [ ] Cold install on a clean Mac: DMG from https://burnbar.ai/download → menu bar → real Claude/Cursor/Codex spend in &lt;5 minutes.
- [ ] Confirm public DMG is `OpenBurnBar-1.0.29-macOS.dmg` (site + provenance test).
- [ ] Confirm `support@burnbar.ai` receives mail and you will answer same-day.
- [ ] Optional: create a 3-question Google Form / Typeform, then paste the URL into `SITE.publicBeta.feedbackFormUrl` in `website/src/data/site.ts` and redeploy.
  - Suggested questions: (1) platform + version (2) did first-run spend look right? (3) what broke / confused you?
- [ ] Enable / pin a GitHub Discussion category post: “Public beta — report here”.
- [ ] Record a 30–60s screen capture: download → Applications → menu bar → spend number.
- [ ] Do **not** claim Windows is ready. Linux = early ARM64 only.
- [ ] Be online Saturday around your post window.

### Suggested form URL step (optional)

1. Create form titled `OpenBurnBar public beta feedback`.
2. Put the share link into `SITE.publicBeta.feedbackFormUrl`.
3. Redeploy website so the top banner “Send feedback” button uses the form.

Until that field is set, the banner links to GitHub Discussions.

## Launch day (Saturday ~noon local is fine)

Order matters more than perfect timing:

1. [ ] Refresh GitHub Release notes using the `github_release` post in `WEEKEND_PUBLIC_BETA_POSTS`.
2. [ ] Confirm https://burnbar.ai shows the public-beta banner and `/download` pins `1.0.29`.
3. [ ] Post **Hacker News** (`Launch HN: …`) — highest leverage for this product.
4. [ ] Post Reddit (one post each, value-first, not crosspost spam):
   - `r/LocalLLaMA`
   - `r/ClaudeAI`
   - `r/cursor`
   - optional: `r/programming`
5. [ ] Indie Hackers post.
6. [ ] X/Twitter thread (nice-to-have; 200 followers will not carry the weekend).
7. [ ] Send **20–30 warm DMs** using the `warm_dm` template.
8. [ ] Hold Product Hunt for a second wave **unless** cold install is dead reliable and you want the louder spike today.

## Feedback collection (keep it dumb)

| Channel | Use for |
| --- | --- |
| GitHub Discussions | Public beta thread / questions |
| GitHub Issues | Reproducible bugs / wrong provider numbers |
| `support@burnbar.ai` | Private / sensitive / billing |
| Optional form | Structured weekend intake |
| Opt-in analytics only | Do not turn on silent telemetry for beta |

Ask every installer one specific question:

> Does the first-run cost number match what you expect within ~10%?

### Daily triage ritual (Sat + Sun)

1. Inbox → tag: `crash` / `wrong-number` / `confused-ux` / `install-fail`.
2. Fix or acknowledge the top 3.
3. Reply to every human reporter the same day.
4. Keep a running “known issues” note in the Discussion thread.

## Exact post drafts

Copy from `WEEKEND_PUBLIC_BETA_POSTS` in [`website/src/data/launch.ts`](../website/src/data/launch.ts). Do not invent a broader platform story than Mac + iOS Core.

## After the weekend

- [ ] Summarize top 10 issues.
- [ ] Ship a fast patch release if install/parser bugs dominate.
- [ ] Decide second wave: Product Hunt + broader HN follow-up once the top install bugs are quiet.
- [ ] Keep Windows off the marketing site until physical certification is GO.
- [ ] Promote Linux only as early ARM64 beta until x86_64 + cert ledger improve.

## Ready gate (must be true before you post)

1. Stranger-path Mac install works cold.
2. Support inbox is live and monitored.
3. Known bugs are labeled, not hidden.
4. Download CTA version matches the live GitHub Latest DMG.
5. You can handle ~10–50 beta users this weekend.
