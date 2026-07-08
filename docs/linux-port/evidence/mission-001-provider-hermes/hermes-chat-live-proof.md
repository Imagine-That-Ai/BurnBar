# Linux Hermes Chat / Tool Approval Live Proof

Fresh implementation note from `/private/tmp/openburnbar-linux-mission-001` on 2026-07-03:

- `apps/linux-desktop/src/main.ts` now gives the `chat` route a live daemon proof panel instead of the daemon fixture table.
- In packaged evidence mode (`OPENBURNBAR_EVIDENCE_OUT` set), the panel auto-runs through `client.attach`, provider config/credential seeding, `run.create`, `run.poll`, approval request/render/response, cancellation, retry, and transcript listing through the Tauri `daemon_rpc` bridge.
- `scripts/linux-port/start-shell-session-daemon.sh` now launches the daemon with deterministic `BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE` payloads so the browser proof can run without external provider credentials.
- `scripts/linux-port/run-provider-hermes-evidence.sh` records the same run create/list/get/poll/approval/cancel/retry flow in `cli-hermes-transcript.txt` as a headless daemon-backed supplement.

Canonical companion:

- `docs/linux-port/fixtures/hermes-event-order-source-oracle.json` is the accepted event-order source oracle. `hermes-event-order-diff-macos.json` and `hermes-event-order-diff-linux.json` must be `exact_match`.
