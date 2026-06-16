# Open Questions and Decisions Needed

| ID | Question | Options | Recommended | Owner | Impact |
|---|---|---|---|---|---|
| Q-001 | Will SQLCipher ship in the next release, or will claims be updated? | A) Ship SQLCipher B) Update claims C) Both | A | Platform/Product | Core privacy claim |
| Q-002 | Is App Check currently enforced for Firestore in production? | Yes / No / Partial | Need audit | Backend | Cloud sync security |
| Q-003 | Should Computer Use be default-off or Manual-only until adversarial tests pass? | A) Default-off B) Manual-only C) Current | A or B | Product/Security | Safety |
| Q-004 | Should local MCP require explicit user approval for every search? | Yes / No | Yes | AI/Agentic | Data exfiltration |
| Q-005 | What is the retention/deletion SLA for `ops/` telemetry? | Define 30/90/365 days | 90 days | Ops/Legal | Compliance |
| Q-006 | Will the release workflow require two-person approval? | Yes / No | Yes | Ops | Supply chain |
| Q-007 | Should provider/cost metadata be encrypted with a user key? | Yes / No / Later | Later | Backend/Privacy | Metadata profiling |
| Q-008 | Is the Cursor connector quick tunnel required for launch? | Yes / No / Opt-in | Opt-in with warnings | Extensions | Local attack surface |
| Q-009 | What is the plan for Remote Unlock helper missing from bundle? | Fix before launch / Defer / Remove feature | Fix before launch | Computer Use | Feature completeness |
| Q-010 | Should daemon RPC use per-client ephemeral tokens? | Yes / No | Yes | Daemon | Local privilege isolation |
