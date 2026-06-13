# Open Questions

These require founder, engineering, product, or operations decisions. They should be resolved or explicitly accepted before external audit.

## Product and Claims

1. What exact user-facing encryption claim is BurnBar willing to make: sealed Gateway flows only, local-first, or broader E2EE?
2. Will BurnBar explicitly avoid Signal-level claims until Signal Gateway writes are production-ready?
3. How should users be told that endpoints remain plaintext trust boundaries?
4. What autonomy levels are acceptable by default, and who can enable YOLO/unrestricted shell?
5. Should local MCP be treated as a trusted-only developer interface or hardened for untrusted agents?

## Pairing and Devices

1. Is user-visible safety-code verification mandatory for all pairings?
2. What is the revocation SLA for server access, push, MCP, provider credentials, and local data purge?
3. Should high-risk approvals require biometric/passcode/user-presence on mobile?
4. What happens when there is no surviving trusted device for CloudVault rotation?

## Cloud and Operations

1. Who can access production Firestore, Storage, Functions logs, Secret Manager, and KMS decrypt?
2. Are all production data/admin accesses logged and reviewed?
3. Are deployed rules and Functions config continuously checked against repository source?
4. What is the break-glass process and how is it audited?
5. Are backups encrypted, access-controlled, and restore-tested?

## Privacy and Data Governance

1. What is the retention period for messages, attachments, metadata, logs, audit events, crash reports, memory, and provider request logs?
2. Which third-party processors are in production: Sentry, Firebase Crashlytics, APNs/FCM, Stripe, OpenRouter, model providers, analytics?
3. Can users export and delete all local and cloud data, including memory and audit records?
4. What provider data retention settings/contracts are in place?

## Agentic AI

1. Should memory writes require user approval or provenance review?
2. What sources are allowed to write persistent memory?
3. Which actions must be reversible or snapshot-protected?
4. What is the kill switch for rogue agents across local daemon, hosted MCP, Gateway, and provider routes?
5. What is the policy for tool output that contains instructions?

## Supply Chain

1. Are all release-signing and deploy credentials protected by hardware-backed or equivalent controls?
2. Will third-party GitHub Actions be SHA-pinned?
3. Will the vendored Hermes/Nous runtime verifier be required in release CI?
4. Is an AIBOM required for model/provider/tool dependencies?
5. Which CI jobs are branch-protection required today?
