# Privacy Threat Model

This analysis uses LINDDUN-style categories and focuses on data collection, metadata, third-party sharing, and user expectation mismatch.

## Data Inventory

| Data type | Purpose | Storage | Retention | Sharing | User visibility/control | Risk | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Prompts/messages | Agent control and history | Local DB; sealed cloud docs where synced | Unknown | Model providers if routed | Partial through app/export | High | Document plaintext locations and provider egress. |
| Model outputs | Display/history/tool decisions | Local/cloud | Unknown | Logs/provider may contain metadata | Partial | High | Treat as untrusted content and sensitive data. |
| Attachments | Agent context/file transfer | Storage ciphertext; local plaintext after open | Unknown | Model provider if encoded; Storage metadata | Partial | High | Add retention/delete and preview warnings. |
| Device IDs/public keys | Pairing/trust | Firestore | Until revoke/delete | Cloud admins | Device settings | Medium | Minimize names; expose device inventory. |
| IP addresses | Rate limit/audit/security | Logs/audit hashed or provider logs | Unknown | Sentry/GCP/provider | Low | Medium | Define retention and hashing policy. |
| Push tokens | Notifications | Firestore/provider | Unknown | APNs/FCM | Device settings | Medium | Rotate/delete on logout/revoke. |
| Usage logs/audit | Security/debug/cost | Cloud/local logs | Unknown | Sentry/GCP | Limited | Medium/High | Retention, redaction corpus, access controls. |
| Provider credentials | Model access | Secret Manager/KMS/local Keychain | Until revoked/destroyed | Cloud IAM/provider | Account settings | High | IAM evidence, rotation, least privilege. |
| Agent memory | Personal/project memory | Local/cloud sealed/cloaked | Unknown | Model/embed providers if used | Unclear | High | User review/delete, provenance, secret scan. |
| Billing data | Entitlements/payments | Stripe/Firestore | Processor dependent | Stripe | Account | Medium | Processor inventory and deletion mapping. |
| Crash reports | Reliability/security triage | Sentry/Crashlytics | Provider dependent | Sentry/Firebase | Limited | Medium/High | Native/mobile crash redaction tests. |

## LINDDUN Analysis

| Category | Scenario | Impact | Existing control | Gap | Recommendation |
| --- | --- | --- | --- | --- | --- |
| Linking | Cloud links devices, messages, attachments, usage, MCP activity by uid/client IDs. | Behavioral profile | Owner-scoped docs; hashed audit fields in hosted MCP | Metadata minimization incomplete | Minimize identifiers, define retention, separate audit scopes. |
| Identifying | Device names, provider accounts, push tokens, IP/user agent can identify user/device. | Re-identification | Some hashing/truncation/redaction | Complete data map absent | Document all identifiers and user-visible controls. |
| Non-repudiation | Audit logs can prove user/device actions. | Useful for security but privacy-sensitive | Computer-use audit, hosted MCP audit | User expectations unclear | Explain action history and retention. |
| Detecting | Cloud can infer usage patterns from sizes/timestamps/tool names. | Sensitive routine/project inference | Sealed contents | Metadata remains visible | Avoid "private from BurnBar" broad wording. |
| Data disclosure | Logs/crashes/provider calls may include prompts, attachments, secrets. | Sensitive data exposure | Sentry/log scrubbers, provider routing | Native/mobile/provider redaction incomplete | Redaction corpus tests and provider retention controls. |
| Unawareness | Users may not realize hosted answers or attachments go to providers. | Consent/expectation mismatch | Privacy mode and route code | UX proof not reviewed | Provider egress indicators and per-call disclosure. |
| Non-compliance | Retention/deletion/export incomplete across local/cloud/providers. | Legal/regulatory risk | Data export/delete callables, panic flow | Processor deletion mapping not complete | Data retention schedule and deletion verification. |

## Privacy Claims

| User belief | What code supports | Safe wording | Unsafe wording |
| --- | --- | --- | --- |
| BurnBar cannot read my messages. | Current sealed Gateway writes should hide content from cloud; metadata remains; legacy/local/provider paths differ. | "Current sealed relay payloads are encrypted before cloud relay." | "We cannot read your messages." |
| Attachments are private. | Current Gateway upload seals attachments before Storage; local/provider preview can expose; download auth uncertain. | "Current relay uploads store encrypted attachment bodies." | "Attachments are private everywhere." |
| Agents run only on my computer. | Local-first architecture, but hosted MCP/provider/Functions paths exist. | "Core agent execution is local-first, with optional cloud/provider services." | "Everything stays local." |
| Providers do not see my data. | Provider routes can receive digests, prompts, and encoded attachments. | "Provider requests are made only on configured routes and may include task data." | "Model providers never see your data." |
| Logs are anonymous. | Scrubbers hash/truncate some fields; metadata remains. | "Logs are scrubbed and minimized where implemented." | "Logs are anonymous." |
| Deleting a device deletes access. | Future server access can be revoked; local copies remain. | "Revocation blocks future server access for that device token." | "Deletion removes all copies instantly." |

## Privacy Recommendations

1. Publish a data map with retention and deletion for local DB, Firestore, Storage, logs, Sentry, Crashlytics, model providers, push providers, and Stripe.
2. Add user-visible provider egress indicators for hosted answer, selected model routes, and attachment encoding.
3. Define metadata minimization goals for Gateway: device names, client IDs, sizes, timestamps, hashes, and status fields.
4. Add crash/log redaction tests with real prompt, secret, attachment, path, and tool-argument fixtures.
5. Add per-user export/delete verification tests that include MCP, memory, search indexes, attachments, provider credentials, push tokens, and audit logs.
6. Make memory review/delete and source provenance user-visible.
7. Define retention and access policy for action audit logs.
