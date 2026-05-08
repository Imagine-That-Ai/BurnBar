# Claude UI Handoff: Remote Quota Sync Polish

## Goal

Polish the iOS/iPadOS provider-add and quota-refresh UI for Claude Code and
Codex remote quota sync. Keep behavior unchanged unless a bug is found.

## Current Implementation

- Codex shows `Hosted` and `Self-hosted` modes.
- Claude Code shows self-hosted runner setup only.
- Hosted Codex mode requires the StoreKit product
  `com.openburnbar.hostedQuotaSync.monthly` before account connection.
- Self-hosted mode stores only runner URL and optional runner secret on-device.
- Account refresh uses the normal account row refresh action. Local-only
  self-hosted accounts call the runner from device, then upload sanitized
  snapshots.

## Product Constraint

Do not add hosted Claude Code setup-token collection without a permitted
commercial/API path. Current Anthropic Claude Code legal guidance does not allow
third-party developers to route Free, Pro, or Max credentials on behalf of users.

## Claude-Owned Polish

- Make Codex hosted vs self-hosted visually distinct without adding a new page.
- Make Claude Code self-hosted-only setup feel intentional and trustworthy.
- Clarify the credential/setup prompts:
  - Claude Code: configure auth in your own self-hosted runner.
  - Codex hosted: paste the contents of `~/.codex/auth.json`.
- Clarify self-hosted setup with concise helper text and validation state.
- Make error states actionable but short.
- Preserve existing account list layout and provider rows.

## Files

- `OpenBurnBarMobile/Views/AddProviderConnectionView.swift`
- `OpenBurnBarMobile/Views/ProviderConnectionsView.swift`
- `OpenBurnBarMobile/Models/HostedQuotaSubscriptionStore.swift`
- `OpenBurnBarMobile/Models/SelfHostedQuotaRunnerStore.swift`

## Acceptance

- No UI overlap on iPhone and iPad.
- Codex hosted and self-hosted flows are visually distinct.
- Claude Code self-hosted-only state is clear.
- Existing non-Claude/Codex provider connection UI is not redesigned.
- VoiceOver labels remain clear for Subscribe, Connect, and Refresh.
