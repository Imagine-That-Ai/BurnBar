# Security Definition

## B.1 What the Product Does

OpenBurnBar is a developer productivity and AI-agent orchestration product with local, mobile, and cloud components. It tracks usage and cost, stores local and cloud-encrypted session data, connects desktop and mobile clients, supports hosted and local MCP access, provides billing, and includes agentic Computer Use flows that can operate browser or system actions under policy and approval controls.

Primary workflows:

- Sign in through Firebase-backed identity providers and passkeys.
- Capture, store, summarize, export, and delete usage/session data.
- Sync encrypted records through Firestore and Cloud Storage.
- Use mobile apps for approvals and cross-device workflows.
- Run a local daemon and gateway for desktop-local control.
- Grant hosted MCP access with scoped short-lived tokens and local decryption.
- Subscribe and manage billing through Stripe.
- Execute Computer Use actions under policy, approvals, and audit.

Security-critical flows:

- Authentication and object-level authorization.
- High-risk owner actions: export, remote MCP grant, revoke, agentic actions.
- Local daemon RPC and HTTP gateway admission.
- Computer Use approval and audit.
- Cloud Vault encryption and key storage.
- Billing webhook verification and redirect validation.
- Data deletion and audit evidence.
- CI/CD release integrity.

## B.2 Definition of Secure

### Users

Secure means:

- User data is not exposed to other users, unauthorized services, or unintended third parties.
- Only authorized users and devices can access or mutate their resources.
- High-impact actions require meaningful authorization at the boundary where the action occurs.
- Local secrets and vault keys are stored in OS-protected storage and fail closed on persistence errors.
- Deletion, export, and retention behavior matches product promises.
- Security and privacy claims are precise and not stronger than the implementation.

### Product

Secure means:

- Trust boundaries are explicit between clients, daemon, mobile devices, Firebase, hosted MCP, Stripe, and CI/CD.
- Controls are implemented in code, tested, and monitored.
- High-risk flows fail closed, not best effort, except where a deliberate privacy decision is documented.
- App Check, high-risk nonces, owner checks, and policy gates are consistently enforced.
- Logs and crash reports are scrubbed before leaving the component.
- Regressions are caught by unit, emulator, static, and CI policy tests.

### Business

Secure means:

- Public and enterprise claims are defensible from code and deployment evidence.
- Production access, deploy rights, and secret access are least privilege and reviewable.
- Incidents can be investigated using durable, tamper-evident audit events where appropriate.
- Supply-chain risk is managed through pinned dependencies/actions, scanning, provenance, and release review.
- Risk exceptions are tracked as explicit findings or accepted risks.

## B.3 Security Goals

| ID | Goal |
|---|---|
| GOAL-001 | Protect confidentiality of user session data, prompts, outputs, usage records, and account data. |
| GOAL-002 | Prevent cross-user and cross-tenant Firestore, Storage, hosted MCP, and Function access. |
| GOAL-003 | Require strong owner proof for high-risk actions. |
| GOAL-004 | Prevent unauthorized local daemon and Computer Use actions. |
| GOAL-005 | Minimize sensitive logging and crash-report leakage. |
| GOAL-006 | Keep billing and webhook flows integrity-protected. |
| GOAL-007 | Keep local vault, database, and provider credentials in OS-protected storage. |
| GOAL-008 | Provide durable audit evidence for high-risk actions. |
| GOAL-009 | Secure the release pipeline and detect dependency or secret regressions. |
| GOAL-010 | Make future audit reruns deterministic and comparable. |

## B.4 Non-Goals

| ID | Non-goal |
|---|---|
| NON-GOAL-001 | The product does not protect plaintext on a fully compromised endpoint after authorized decryption. |
| NON-GOAL-002 | The product does not provide anonymity. Account identifiers, billing IDs, and usage metadata exist. |
| NON-GOAL-003 | The product does not prevent screenshots, shoulder surfing, or OS-level observation by a compromised device. |
| NON-GOAL-004 | The current evidence does not support universal Signal-quality E2EE across all data. |
| NON-GOAL-005 | Prompt instructions or model refusals are not treated as security boundaries. |
| NON-GOAL-006 | Repository code alone does not prove Firebase console, IAM, or Cloud Armor production state. |
| NON-GOAL-007 | Local-first does not mean cloud data is absent; Firestore, Storage, hosted MCP, Sentry, Stripe, and push providers are in scope. |

## Assumptions

- Product name: OpenBurnBar / BurnBar.
- Product type: local app, desktop app, mobile app, API service, hosted MCP service, browser extension, AI/agentic product, cloud-backed SaaS features.
- Primary users: developers and teams using AI/dev tooling.
- Business model: subscription with Stripe-backed Pro entitlement.
- Deployment model: local desktop/mobile clients plus Firebase and hosted Node services.
- Compliance needs: app store review, enterprise procurement, privacy/GDPR-style deletion/export, SOC 2-style controls likely relevant.

