# Security Definition

## What the Product Does

OpenBurnBar is a developer productivity and AI-agent orchestration product with local, mobile, and cloud components. It tracks usage and cost, stores local and cloud-encrypted session data, connects desktop and mobile clients, supports hosted and local MCP access, provides billing, and includes agentic Computer Use flows that can operate browser or system actions under policy and approval controls.

## Definition of Secure

For users:

- User data is not exposed to other users, unauthorized services, or unintended third parties.
- Only authorized users and devices can access or mutate their resources.
- High-impact actions require meaningful authorization at the boundary where the action occurs.
- Local secrets and vault keys are stored in OS-protected storage and fail closed on persistence errors.
- Deletion, export, and retention behavior matches product promises.
- Security and privacy claims are precise and not stronger than implementation.

For the product:

- Trust boundaries are explicit between clients, daemon, mobile devices, Firebase, hosted MCP, Stripe, and CI/CD.
- Controls are implemented in code, testable, and monitored.
- High-risk flows fail closed except where a deliberate privacy decision is documented.
- Logs and crash reports are scrubbed before leaving the component.
- Regressions are caught by unit, emulator, static, and CI policy tests.

For the business:

- Enterprise claims are defensible from code and deployment evidence.
- Production access, deploy rights, and secret access are least privilege and reviewable.
- Incidents can be investigated using durable audit events where appropriate.
- Supply-chain risk is managed through pinned dependencies/actions, scanning, provenance, and release review.

## Security Goals

| ID | Goal |
|---|---|
| GOAL-001 | Protect confidentiality of user session data, prompts, outputs, usage records, and account data. |
| GOAL-002 | Prevent cross-user Firestore, Storage, hosted MCP, and Function access. |
| GOAL-003 | Require strong owner proof for high-risk actions. |
| GOAL-004 | Prevent unauthorized local daemon and Computer Use actions. |
| GOAL-005 | Minimize sensitive logging and crash-report leakage. |
| GOAL-006 | Keep billing and webhook flows integrity-protected. |
| GOAL-007 | Keep local vault, database, and provider credentials in OS-protected storage. |
| GOAL-008 | Provide durable audit evidence for high-risk actions. |
| GOAL-009 | Secure the release pipeline. |
| GOAL-010 | Make future audit reruns deterministic and comparable. |

## Non-Goals

- Does not protect plaintext on a fully compromised endpoint after authorized decryption.
- Does not provide anonymity.
- Does not prevent screenshots, shoulder surfing, or OS-level observation by a compromised device.
- Does not currently prove universal Signal-quality E2EE across all data.
- Does not treat prompt instructions or model refusals as hard security boundaries.
- Repository code alone does not prove Firebase console, IAM, Cloud Armor, or branch-protection state.

