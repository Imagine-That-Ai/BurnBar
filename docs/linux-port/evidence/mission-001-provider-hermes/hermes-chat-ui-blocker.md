# Linux Hermes Chat / Tool Approval UI Blocker

Fresh check from `/private/tmp/openburnbar-linux-mission-001` on 2026-07-03:

- `apps/linux-desktop/src/routes.ts` defines a `chat` route labeled `Chat / Hermes`.
- `apps/linux-desktop/src/main.ts` handles dashboard data routes, including `chat`, through `appendDaemonDataTable(...)`.
- `apps/linux-desktop/src/daemonFixture.ts` defines the chat row as a placeholder: `Thread list requires live daemon; fixture shows placeholder thread.`
- `docs/linux-port/evidence/mission-001-shell-ux/daemon-route-transcript.json` and `route-a11y-user-flow-transcript.json` prove navigation to `#/chat`, but they do not send a Hermes prompt, stream assistant/tool/done events, render approval controls, or persist a chat transcript.

Impact:

- `VAL-HERMES-001` cannot be honestly passed from the W06 shell route evidence because the route is present but not a live daemon-backed Hermes chat/tool approval workflow.
- `VAL-HERMES-003` remains partial: Linux `LLMSafeContent` prompt-injection fixture tests pass, but the contract also requires wrapper evidence through Hermes chat/tool surfaces, which depends on `VAL-HERMES-001`.

