# Cure53 Audit Brief

## System Overview

BurnBar/OpenBurnBar is a local-first remote AI-agent control system. Users can control AI agents running on their computers from mobile and other clients. The repository includes desktop and mobile apps, a local daemon, Firebase cloud services, Hermes Gateway relay, CloudVault sealing, hosted/local MCP tooling, provider integrations, and release/deploy automation.

The security model is not "the cloud is blind to everything." The model is:

- current sealed Gateway content should be opaque to the cloud;
- the cloud remains trusted for authentication, authorization, metadata, routing, and some provider/secret operations;
- endpoints are trusted while uncompromised;
- agent/tool execution is high risk and must be policy-gated, approved, logged, and bounded.

## Proposed Scope

In scope:

- Swift crypto: CloudVault, Hermes relay, ratchet, Signal-at-rest, Iroh pairing.
- Gateway backend: pairing, bearer+PoP, message/event/attachment relay, approvals, revocation.
- Firebase rules and Storage paths.
- Auth/App Check/high-risk nonce/trusted-device proof.
- Local daemon IPC, run service, tool dispatch, computer-use coordinator, audit.
- Local and hosted MCP authz and data exposure.
- Mobile key storage, pairing, notifications, attachment open.
- Provider credential storage and hosted answer/model egress.
- Logging/Sentry/privacy controls.
- CI/CD, supply chain, release provenance, vendored runtime.

Out of scope by default:

- Live production destructive testing.
- Third-party model/provider internals.
- Formal verification of cryptographic protocols.
- Malware on fully compromised endpoints, except for residual-risk analysis.

## Setup

Auditors should receive:

- Source access to this repository and submodules/vendor directories.
- Build instructions for macOS, iOS, Android, Functions, hosted MCP, local MCP.
- A dedicated Firebase test project with deployed rules/functions matching source.
- Test accounts for at least two users and multiple devices per user.
- App Check test tokens and high-risk nonce test helpers.
- Test provider keys with strict spend limits.
- Local macOS test machine with daemon/app signing mode documented.
- Test mobile devices or simulators/emulators.

## Key Flows To Test

1. User login/Auth/App Check enforcement.
2. Device registration and pairing.
3. Phone-to-cloud-to-desktop sealed message.
4. Desktop-to-phone sealed response.
5. Attachment upload, finalize, download, open, and provider encoding.
6. Device revocation and post-revocation access attempts.
7. High-impact tool approval for shell/patch/browser/mac input.
8. Prompt injection through document/web/tool output/memory.
9. Hosted MCP token issuance, refresh, scope checks, resource access.
10. Provider credential storage/retrieval and model request egress.

## Security Claims To Validate

- Current Gateway message writes are sealed-only and reject plaintext.
- Cloud cannot decrypt current sealed Gateway contents without endpoint keys.
- Gateway PoP prevents bearer-only replay and request tampering.
- Pairing binds account, device, relay key, and token.
- Firestore/Storage rules deny cross-user client SDK access.
- Callables enforce object ownership even through Admin SDK paths.
- High-impact local tools cannot run without approval except explicit high-risk modes.
- Provider credentials are KMS/Secret Manager protected and least-privilege in production.
- Logs/Sentry scrub secrets and prompt-like payloads in server code.

## Known Issues To Disclose

- No claim of universal E2EE or Signal-level Gateway messaging.
- Signal v4 Gateway writes are not production-ready in repository evidence.
- Full forward secrecy/post-compromise recovery is not proven for all relay paths.
- Gateway attachment download authorization appears inconsistent between mobile code and `storage.rules`.
- Swift CloudVault vault key generation ignores `SecRandomCopyBytes` return status.
- Revocation is future-server-access control; local copies and compromised endpoints remain residual risk.
- Local MCP and YOLO/shell grants are highly privileged.
- Memory poisoning protections are incomplete.
- Live production IAM/App Check/rules/branch protection were not verified by this package.
- Some CI actions are tag-pinned and vendored runtime provenance needs a blocking release gate.

## Questions For Cure53

1. Can the relay or cloud operator cause a client to accept a replayed old valid envelope?
2. Are all Gateway AAD fields sufficient and consistently verified?
3. Is the pairing ceremony resistant to MITM/phishing without mandatory safety-code verification?
4. Are all callable endpoints free of BOLA/IDOR through Admin SDK paths?
5. Can local MCP be safely exposed to any agent, or must it be capability-gated?
6. Can prompt injection induce high-impact tool execution or low-risk data exfiltration?
7. Can memory poisoning persist across tasks and influence tools?
8. Is attachment download authorization correct and secure?
9. Can malicious attachment parsing compromise mobile/desktop clients?
10. Are provider credential IAM/KMS controls sufficient in live production?
