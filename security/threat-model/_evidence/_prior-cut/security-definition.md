# Definition of Secure for BurnBar

This definition is intentionally conservative. A statement is a security claim only if implementation evidence supports it. Documentation, comments, product names, and intent are not enough.

## Secure for Users

Secure for users means BurnBar protects the user from unauthorized remote control, unintended disclosure, and silent high-impact agent behavior within the limits of the endpoint and agent trust model.

Goals:

- Current sealed Hermes Gateway messages and attachments are not readable by BurnBar Cloud without endpoint private keys.
- Attachments are encrypted before upload on current Gateway write paths and are associated with opaque metadata where implemented.
- Only paired and authorized devices can exchange trusted Gateway traffic.
- Revoked devices lose server-side tokens and future cloud access, while already-downloaded plaintext and compromised local keys remain residual risk.
- High-impact actions such as terminal execution, patching, browser control, and desktop input are gated by deterministic policy and user approval.
- Users can see and approve high-impact actions before execution where the code classifies the action as high risk.
- Sensitive data is scrubbed from server logs and Sentry events by repository code, while complete native/mobile crash-log coverage remains uncertain.
- A cloud relay compromise should not reveal current sealed content, but can reveal metadata, drop traffic, replay within gaps, and target users.
- A compromised paired device or desktop endpoint is not protected from local plaintext exposure.

Non-goals:

- BurnBar does not guarantee confidentiality from a compromised paired device.
- BurnBar does not guarantee anonymity or metadata hiding.
- BurnBar does not prevent screenshots, shoulder surfing, OS-level malware, or user-authorized disclosure to a model provider.
- BurnBar does not currently prove Signal-level secure messaging properties for Hermes Gateway.
- BurnBar does not prove hardware-backed, biometric-gated, non-exportable keys.
- BurnBar does not guarantee malicious model output, documents, webpages, or tool output are safe.

## Secure for the Product

Secure for the product means the architecture has explicit trust boundaries and each security-critical path has code-backed controls, tests, and operational evidence.

Goals:

- Cloud relay, Firestore, Storage, hosted MCP, local daemon, mobile app, desktop app, provider gateways, and CI/CD are separate trust zones.
- Security-sensitive interfaces authenticate callers and authorize per object, device, user, or grant.
- Server-only Firestore collections and callable Functions enforce ownership rather than relying on client behavior.
- App Check is enforced for production-looking Firebase projects by configuration defaults.
- Hermes Gateway refuses new plaintext Gateway writes and requires relay-capable endpoints for sealed flows.
- High-risk cloud actions use high-risk nonces and trusted native device proof where implemented.
- Security failures fail closed for App Check, high-risk nonce validation, PoP validation, malformed sealed envelopes, and daemon peer authentication in production builds.
- Critical controls have tests or are flagged as test gaps.
- Incident response paths exist in docs/code for panic/revocation flows, but live operational readiness is not proven.

Non-goals:

- The product does not treat cloud infrastructure as fully untrusted. Cloud still performs authorization, stores metadata, issues signed URLs, stores provider secret envelopes, and runs hosted answer/MCP services.
- The product does not prove every callable endpoint has complete BOLA tests.
- The product does not prove complete production IAM least privilege from repository files alone.

## Secure for the Business

Secure for the business means BurnBar can make defensible claims, prioritize risks, and give auditors a reproducible review surface.

Goals:

- Security posture can be explained as local-first with sealed subflows, not universal E2EE.
- Risks are tracked by severity, owner, and testable mitigation.
- User-facing wording does not overstate endpoint compromise protection, metadata privacy, Signal-level security, or model safety.
- Logging supports debugging and incident response while minimizing plaintext and secrets.
- Supply-chain controls include secret scanning, dependency review, OSV/npm audit, CodeQL, release notarization/signing, SBOM/VEX, and provenance work where implemented.
- Release and infrastructure controls are verified before external audit with live evidence, not only repository intent.

Non-goals:

- BurnBar does not claim regulatory compliance from this package.
- BurnBar does not claim production zero trust until live IAM, network, KMS, CI, and access review evidence exists.
- BurnBar does not claim all supply-chain risk is eliminated; it aims for visible, monitored, and bounded risk.

## Assumptions

| Assumption | Status | Impact if false |
| --- | --- | --- |
| Endpoint OS keychains/keystores behave as documented when the endpoint is uncompromised. | Assumed | Local keys and tokens may be easier to extract. |
| Firebase Auth/App Check tokens are validated by deployed Functions as in repository code. | Unknown until live proof | Cross-user or forged-client calls may be possible. |
| Deployed Firestore/Storage rules match repository files. | Unknown until live proof | Repository access claims may not reflect production. |
| Paired devices remain under user control unless revoked or compromised. | Assumed | An attacker can read plaintext and approve actions. |
| Model providers process data according to configured accounts/contracts. | Unknown | Provider egress can expose prompts, attachments, and digests. |
| User approvals are meaningful and not habituated or phished. | Partial | Agentic attacks can socially engineer high-impact approvals. |

## Security Claims

The claims below are summarized. The detailed claim matrix is in [security-claims.md](security-claims.md).

| Claim | Status |
| --- | --- |
| Current Hermes Gateway sealed message writes are not plaintext writes. | Defensible |
| Cloud relay cannot decrypt current sealed Gateway content without endpoint keys. | Partially defensible |
| Cross-user Firestore access is denied by rules and callable ownership checks. | Partially defensible |
| High-impact local tools are policy/approval gated. | Partially defensible |
| App Check is enforced in production-looking Firebase configuration. | Partially defensible |
| Logs/Sentry are scrubbed for obvious secrets. | Partially defensible |
| Removed devices lose all access immediately. | Not defensible |
| BurnBar provides Signal-level security for Gateway messaging. | Not defensible |
| Keys are hardware-backed or biometric gated. | Not defensible |
| Untrusted content cannot manipulate agents. | Not defensible |

## Non-Claims

BurnBar should explicitly avoid claiming:

- "End-to-end encrypted everywhere."
- "Signal-level security."
- "Full forward secrecy."
- "The cloud cannot learn anything about usage."
- "Removed devices lose all access immediately."
- "Agents cannot be prompt-injected."
- "Malicious attachments are safe."
- "Keys are hardware-backed."
- "Logs never contain sensitive data."
- "Local execution is sandboxed in all modes."
- "Provider calls never include user data."
- "BurnBar protects data on a compromised endpoint."
