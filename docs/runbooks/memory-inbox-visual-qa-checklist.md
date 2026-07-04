# Memory review inbox — visual QA checklist (A3)

Operator checklist for signing off [`MEMORY_ACTIVATION.md`](../MEMORY_ACTIVATION.md) §7.6 on a running macOS app build.

## Preconditions

- [ ] Signed-in user with chat-memory consent enabled (Settings → Privacy → Memory)
- [ ] At least one quarantined fact present (run a short Hermes chat with extraction enabled)
- [ ] Build includes inbox route: Dashboard → Memory Review (`DashboardMainRoute.memoryReview`)

## Inbox layout

- [ ] Pending / Approved filter chips switch lists without crash
- [ ] Thread-group bulk approve chip appears when multiple pending facts share a thread
- [ ] Kind, confidence, and redacted body preview render for each row
- [ ] Empty pending state shows honest copy (not a blank screen)

## Actions

- [ ] Approve one fact → moves to Approved filter; recall can surface it in a new chat (wrapped untrusted block)
- [ ] Reject one fact → removed from pending; does not appear in recall
- [ ] Bulk approve on a thread group approves all listed facts
- [ ] Open body (if exposed) shows sealed/redacted handling — no raw secret patterns

## Consent sheet

- [ ] First enable shows consent sheet from Settings shortcut (`PrivacyIndexingSettingsView`)
- [ ] Disable halts new extraction jobs within one worker pump (kill-switch drill)

## Regression

- [ ] `MemoryReviewInboxModelTests` / UI tests green locally
- [ ] Windows inbox (F2): shell route `memory` renders **read-only** synced-memory pane
  - Empty state: “No synced memories yet” (no demo/sample facts)
  - Pending filter and Approve/Reject controls are **hidden**
  - Subtitle explains review stays on Mac

## Sign-off

| Field | Value |
|---|---|
| Build / commit | |
| Tester | |
| Date | |
| Result | PASS / FAIL |
| Notes | |
