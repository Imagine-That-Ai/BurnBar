---
name: openburnbar-resume
description: Resume or continue a prior session through OpenBurnBar hosted MCP.
---

Run the `openburnbar-resume` skill workflow to inspect a resume plan by
explicit opaque session ID:

1. Call `burnbar_resolve_capabilities` first and read the returned tool list.
2. Do not use plaintext topic search to choose a session on the HTTP-only path.
3. Require an explicit opaque session ID supplied by the user or trusted local
   shim, then call `burnbar_resume_conversation`.
4. Print only a decrypted plan. If it remains sealed, name the local-shim
   blocker; never spawn automatically.
