# Mission Control Fleet Architecture

## System Intent
Mission Control Fleet turns one-line operator intent into governed, replayable execution: daemon-owned canonical state plans and runs work across agents/tools, then converges app + extension surfaces to either `completed` or exactly one active approval question.

## Core Architecture Domains
1. **Operator Surfaces (macOS app + extension)** — mission authoring, board, inbox, brief.
2. **Daemon Mission Control API** — canonical mutation boundary and policy enforcement.
3. **Planning Domain** — intent normalization + typed/versioned DAG generation.
4. **Routing/Readiness Domain** — route scoring and fail-closed preflight validation.
5. **Execution Runtime** — dependency-aware scheduler, launcher integration, run journal.
6. **Recovery/Reconciliation Domain** — retry/failover/restart restore and deterministic conflict resolution.
7. **Projection Layer** — deterministic daemon→app/extension mapping and ordering parity.

## Lifecycle State Machine Contract

### Mission States
| State | Meaning |
|---|---|
| `draft` | Mission is authored but not yet submitted for approval/execution. |
| `awaiting_approval` | Mission exists but cannot execute until approved. |
| `approved` | Approval captured; mission is eligible for dispatch/readiness checks. |
| `dispatching` | Mission packet dispatch has started and run linkage is being established. |
| `in_progress` | One or more packets/runs are active. |
| `partially_completed` | Mission has partial completion evidence and remaining work. |
| `completed` | Mission reached terminal success. |
| `failed` | Mission reached terminal failure (non-recoverable). |
| `cancelled` | Mission was explicitly cancelled and is terminal. |

> Canonical source: `BurnBarMissionStatus` in `OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionControlContracts.swift`.
> Labels like `planning`, `ready`, `blocked_approval`, and `reconciling` are runtime/journal phases and reason-code states, not persisted mission status enum values.

### Allowed Events and Transitions
| Event | Allowed From | To | Notes |
|---|---|---|---|
| `mission.create` | — | `awaiting_approval` | Initial persisted state. |
| `mission.approve` | `awaiting_approval` | `approved` | Records actor/note/timestamp. |
| `dispatch.start` | `approved` | `dispatching` | First packet/run dispatch initiated. |
| `run.started` | `dispatching` | `in_progress` | Run is actively executing. |
| `run.partial` | `in_progress` | `partially_completed` | Partial result persisted with pending follow-on work. |
| `run.resume` | `partially_completed` | `in_progress` | Subsequent dispatch/recovery resumes active execution. |
| `run.complete` | `dispatching`, `in_progress`, `partially_completed` | `completed` | Canonical successful terminal mission state. |
| `run.fail` | `dispatching`, `in_progress`, `partially_completed` | `failed` | Canonical failed terminal mission state. |
| `mission.cancel` | non-terminal | `cancelled` | Legal from any non-terminal state. |

### Illegal Transition Rules (must reject)
| Illegal Transition | Rejection Contract |
|---|---|
| Any mutation from `completed`/`failed`/`cancelled` to non-terminal | Reject with `LIFECYCLE_TERMINAL_IMMUTABLE`. |
| `dispatch.start` before `ready` | Reject with `READINESS_NOT_SATISFIED`. |
| `mission.approve` outside `awaiting_approval` | Reject with `LIFECYCLE_INVALID_EVENT`. |
| Multiple concurrent closure-approval questions for one mission | Reject/merge with `CLOSURE_SINGLE_QUESTION_ENFORCED`. |
| Reconcile terminal write when terminal already persisted | Reject with `RECON_DUPLICATE_TERMINAL`. |

## Canonical Data Contract (Field-Level)
All contracts are typed, schema-versioned, and persisted by daemon-owned models.

| Contract | Required Fields | Optional Fields |
|---|---|---|
| `Mission` | `schemaVersion`, `missionID`, `createdAt`, `updatedAt`, `status`, `approval.approved`, `intent.summary`, `riskLevel` | `owner`, `assignee`, `approval.actor`, `approval.note`, `cancelReason`, `metadata` |
| `PlannerInput` | `schemaVersion`, `missionID`, `normalizedIntent`, `constraints`, `riskLevel`, `desiredOutputs` | `workflowHints`, `toolHints`, `policyOverrides` |
| `MissionDAG` | `schemaVersion`, `missionID`, `nodes[]`, `edges[]`, `plannerFingerprint` | `criticalPathHint`, `annotations` |
| `MissionPacket` | `schemaVersion`, `packetID`, `missionID`, `nodeID`, `status`, `createdAt` | `runID`, `dispatchedAt`, `routeID`, `retryOfPacketID` |
| `RunResult` | `schemaVersion`, `runID`, `missionID`, `terminalState`, `endedAt` | `cost`, `tokens`, `provider`, `failureReasonCode`, `evidenceRefs` |
| `ApprovalQuestion` | `schemaVersion`, `questionID`, `missionID`, `status`, `prompt`, `createdAt` | `suggestedAnswers`, `resolvedAt`, `resolvedBy`, `resolutionNote` |
| `MissionBrief` | `schemaVersion`, `missionID`, `status`, `summary`, `riskSummary`, `nextOperatorAction` | `changedFiles`, `remainingWork`, `prLinkage`, `burnSummary` |
| `PRLinkage` | `schemaVersion`, `repository`, `prNumberOrID`, `url`, `state` | `mergeCommitSHA`, `mergedAt`, `closedAt` |

### Versioning Semantics
- `schemaVersion` is mandatory for every persisted/public contract.
- **Minor-compatible evolution**: additive optional fields allowed; old readers ignore unknown fields.
- **Breaking evolution**: required field removal/meaning changes require version bump and explicit decode guard.
- Unsupported versions fail closed with explicit version error codes (never silent coercion).

## Scheduled Reviews + Notification Intents Contract

### Canonical Contracts (Field-Level)
| Contract | Required Fields | Optional Fields |
|---|---|---|
| `ScheduledReview` | `schemaVersion`, `reviewID`, `scopeType`, `scopeID`, `cadence`, `timezone`, `nextDueAt`, `status`, `createdAt`, `updatedAt`, `ownerPrincipalID` | `lastTriggeredAt`, `lastOutcome`, `snoozedUntil`, `windowStartHint`, `windowEndHint`, `metadata` |
| `NotificationIntent` | `schemaVersion`, `intentID`, `sourceType`, `sourceID`, `audienceScope`, `reasonCode`, `severity`, `status`, `createdAt` | `missionID`, `dedupeKey`, `channelTargets`, `expiresAt`, `deliveredAt`, `acknowledgedAt`, `acknowledgedBy`, `metadata` |
| `ReviewTriggerRecord` | `schemaVersion`, `triggerID`, `reviewID`, `windowStartAt`, `windowEndAt`, `triggeredAt`, `outcome` | `intentID`, `failureReasonCode`, `deliverySummary` |

### Lifecycle and Transition Rules
| Event | Allowed From | To | Notes |
|---|---|---|---|
| `review.create` | — | `active` | Persists cadence/scope and first `nextDueAt`. |
| `review.pause` | `active` | `paused` | Stops due-window dispatch while preserving history. |
| `review.resume` | `paused` | `active` | Recomputes `nextDueAt` from cadence + now. |
| `review.trigger` | `active` | `active` | Emits exactly one due-window `ReviewTriggerRecord` and at most one open `NotificationIntent` per dedupe key. |
| `review.retire` | `active`, `paused` | `retired` | Terminal; future triggers are rejected. |
| `intent.enqueue` | — | `queued` | Canonical creation state for delivery work. |
| `intent.dispatch` | `queued` | `dispatched` | Delivery attempted/committed to channel adapter. |
| `intent.acknowledge` | `dispatched` | `acknowledged` | Operator/action consumer explicitly acknowledged. |
| `intent.expire` | `queued`, `dispatched` | `expired` | Delivery relevance window elapsed. |
| `intent.cancel` | `queued`, `dispatched` | `cancelled` | Cancelled by policy/operator action. |

### Invariants
1. At most one non-terminal `ScheduledReview` exists for a given `(scopeType, scopeID, cadence)` tuple.
2. `nextDueAt` is monotonic-forward for an active review except explicit operator backfill with auditable reason code.
3. A due window (`reviewID + windowStartAt + windowEndAt`) yields exactly one `ReviewTriggerRecord`.
4. `NotificationIntent.dedupeKey` is globally unique among non-terminal intents.
5. `acknowledged`/`expired`/`cancelled` intents are terminal and immutable except for append-only delivery receipts.

## Enterprise Policy Config Contract

### Canonical Contracts (Field-Level)
| Contract | Required Fields | Optional Fields |
|---|---|---|
| `EnterprisePolicyConfig` | `schemaVersion`, `policySetID`, `orgID`, `effectiveFrom`, `defaultApprovalMode`, `reasonCodeMapVersion`, `precedenceOrder[]`, `updatedAt` | `effectiveTo`, `description`, `metadata` |
| `BudgetCapRule` | `schemaVersion`, `capRuleID`, `scopeType`, `scopeID`, `window`, `currency`, `amount`, `enforcement` | `softThresholdAmount`, `timezone`, `notifyChannels`, `metadata` |
| `ApprovalModeRule` | `schemaVersion`, `ruleID`, `scopeType`, `scopeID`, `approvalMode`, `appliesToRiskLevels[]`, `updatedAt` | `approverRoleRequirements[]`, `expiresAt`, `metadata` |

### Approval Modes
| Mode | Behavior |
|---|---|
| `auto_low_medium` | Auto-execute low/medium; explicit approval required for high risk. |
| `auto_low_only` | Auto-execute low; explicit approval required for medium/high risk. |
| `manual_all` | Explicit approval required before any dispatch/resume. |
| `role_delegated` | Approval required, but may be satisfied by configured delegated roles for matching scopes. |

### Policy Precedence and Conflict Resolution
Precedence is evaluated from highest to lowest authority:
1. `mission_override`
2. `project_scope`
3. `team_scope`
4. `org_default`
5. `system_default`

Conflict rules:
- **Approval mode:** most restrictive effective mode wins.
- **Budget cap:** lowest effective hard cap wins; soft-threshold notifications merge by dedupe key.
- **Role requirements:** union of required approver constraints (never subtractive).

### Policy Reason-Code Mapping (Canonical)
| Condition | Canonical Reason Code | Operator Action |
|---|---|---|
| Hard cap exceeded before dispatch | `POLICY_BUDGET_HARD_CAP_BLOCKED` | Stop dispatch; require policy/admin intervention. |
| Soft cap exceeded | `POLICY_BUDGET_SOFT_CAP_EXCEEDED` | Emit notification intent; may continue per policy. |
| Approval mode requires gate | `POLICY_APPROVAL_REQUIRED_BY_MODE` | Create approval question before dispatch/resume. |
| Actor role not permitted for requested action | `POLICY_ROLE_FORBIDDEN` | Reject mutation; preserve audit event. |
| Override expired or outside effective window | `POLICY_OVERRIDE_OUT_OF_WINDOW` | Reject override and fall back to next precedence rule. |

### Invariants
1. Exactly one effective `EnterprisePolicyConfig` is active per org at any given timestamp.
2. Every dispatch/resume decision is traceable to a concrete `(policySetID, ruleID(s), reasonCode)` tuple.
3. Policy evaluation is fail-closed: missing policy inputs reject with `POLICY_CONFIGURATION_INVALID`.
4. Budget and approval decisions must produce deterministic outcomes for identical inputs and timestamps.

## Team Collaboration Audit-Trail Contract

### Canonical Contracts (Field-Level)
| Contract | Required Fields | Optional Fields |
|---|---|---|
| `AuditTrailEvent` | `schemaVersion`, `auditEventID`, `occurredAt`, `sequence`, `eventType`, `scopeType`, `scopeID`, `actorPrincipalID`, `actorRole`, `outcome`, `reasonCode` | `missionID`, `projectID`, `targetPrincipalID`, `correlationID`, `policySnapshotID`, `metadata` |
| `OwnershipTransferRecord` | `schemaVersion`, `transferID`, `scopeType`, `scopeID`, `fromPrincipalID`, `toPrincipalID`, `requestedBy`, `status`, `createdAt`, `updatedAt` | `approvedBy`, `approvedAt`, `rejectedBy`, `rejectedAt`, `note`, `reasonCode` |
| `RoleScopedActionRecord` | `schemaVersion`, `actionRecordID`, `actionType`, `scopeType`, `scopeID`, `actorPrincipalID`, `actorRole`, `decision`, `reasonCode`, `occurredAt` | `requiredRole`, `policySnapshotID`, `targetPrincipalID`, `evidenceRefs` |

### Ownership Transfer Lifecycle
| Event | Allowed From | To | Notes |
|---|---|---|---|
| `ownership.transfer.request` | — | `pending_approval` | Captures from/to principals and requester identity. |
| `ownership.transfer.approve` | `pending_approval` | `completed` | Atomically updates ownership pointer and emits audit event pair (`ownership.revoked`, `ownership.assigned`). |
| `ownership.transfer.reject` | `pending_approval` | `rejected` | Terminal; ownership remains unchanged. |
| `ownership.transfer.cancel` | `pending_approval` | `cancelled` | Terminal operator/admin cancellation. |

### Role-Scoped Action Rules
- Every privileged mutation is authorized against current role bindings and persisted as `RoleScopedActionRecord` whether allowed or denied.
- Denied actions must not mutate business state but must emit `AuditTrailEvent` with `outcome=denied`.
- Role evaluation uses snapshot-consistent policy/role views to keep replay deterministic.

### Audit Projection Fields (App/Extension Parity)
Daemon projection rows consumed by app + extension must expose:
- `auditEventID`, `sequence`, `occurredAt`
- `scopeType`, `scopeID`, `missionID`, `projectID`
- `actorPrincipalID`, `actorRole`, `targetPrincipalID`
- `eventType`, `outcome`, `reasonCode`
- `correlationID`, `policySnapshotID`
- `displaySummary`, `operatorActionHint`

### Invariants
1. Audit trail is append-only and sequence-authoritative; projections cannot rewrite historical events.
2. Ownership transfer completion is atomic with ownership pointer update and audit emission.
3. Role-denied actions are fully visible in audit projections with canonical reason code parity across surfaces.
4. Replay of identical audit events yields identical ownership and permission projections.

## Determinism Contract

### ID Generation Intent
| Identifier | Determinism Rule |
|---|---|
| `missionID` | Generated once at daemon create boundary; immutable for mission lifetime. |
| `nodeID` / `edgeID` | Derived deterministically from `schemaVersion + missionID + canonical node/edge payload`. |
| `packetID` | Stable logical packet identity; re-dispatch upserts same packet rather than duplicating. |
| `runID` | Launcher-issued execution identity bound once to packet dispatch event. |
| `journalEventID` | Unique per run event with monotonic sequence semantics. |

### Ordering and Tie-Break Rules
- Mission listing: `updatedAt DESC`, tie-break `missionID ASC`.
- Route ranking: capability/policy fitness first, then trust, then latency, then cost, then deterministic lexical route ID tie-break.
- Cross-surface projection ordering must use the same canonical comparator inputs and tie-break chain.

### Winner Selection Precedence (Reconciliation)
Conflicting candidate outcomes are resolved by this fixed precedence:
1. Policy-valid and dependency-complete candidates only.
2. Successful terminal outcomes over failed outcomes.
3. Higher evidence completeness (tests/artifacts/required outputs).
4. Lower risk residual.
5. Lower normalized cost/latency penalty.
6. Earliest terminal sequence number.
7. Final tie-break: lexical candidate ID.

Persisted winner must include `winnerReasonCode` + structured rationale payload.

## Reason-Code and Risk Taxonomy (Cross-Surface Mapping)

### Reason-Code Families
| Family | Purpose | Example Codes |
|---|---|---|
| `LIFECYCLE_*` | Illegal state/event transitions | `LIFECYCLE_INVALID_EVENT`, `LIFECYCLE_TERMINAL_IMMUTABLE` |
| `READINESS_*` | Preflight gating failures | `READINESS_MISSING_CREDENTIAL`, `READINESS_REPO_INVALID`, `READINESS_RUNTIME_UNAVAILABLE` |
| `POLICY_*` | Policy/approval/autonomy enforcement | `POLICY_HIGH_RISK_REQUIRES_APPROVAL`, `POLICY_ROLE_FORBIDDEN` |
| `ROUTER_*` | Routing/ranking failures | `ROUTER_NO_ELIGIBLE_ROUTE`, `ROUTER_POLICY_FILTERED_ALL` |
| `RECOVERY_*` | Retry/failover/restart limits | `RECOVERY_RETRY_EXHAUSTED`, `RECOVERY_RESTORE_FAILED` |
| `RECON_*` | Reconciliation and terminal conflicts | `RECON_DUPLICATE_TERMINAL`, `RECON_NO_VALID_WINNER` |

### Risk Levels
| Risk | Autonomy Behavior |
|---|---|
| `low` | Auto-execute in aggressive mode. |
| `medium` | Auto-execute unless stricter policy is configured. |
| `high` | Always require explicit approval before execution/resume. |

### Cross-Surface Mapping Contract
- Daemon emits canonical `reasonCode`, `reasonCategory`, `riskLevel`, `operatorActionHint`.
- App and extension map the same tuple to surface copy/actions without altering code semantics.
- UI wording may differ, but reason code identity and required operator action must remain equivalent.

## Run Journal and Replay Contract

### Journal Guarantees
- Append-only, per-run ordered event stream.
- Monotonic `sequence` per run; sequence order is authoritative over wall-clock timestamps.
- At most one logical terminal event per run (`completed|failed|cancelled`).
- All recovery actions (retry/failover/restore) are explicit journal events, never implicit side effects.

### Replay Guarantees
- Replaying identical journal events yields identical mission/run projections.
- Duplicate/out-of-order ingestion is normalized to one deterministic final state.
- Checkpoint resume restores pending approvals/tools before accepting new mutation paths.
- Replay must preserve public evidence fields (cost/tokens/provider, reason codes, PR linkage) and winner rationale.

## Cross-Surface Convergence Contract
- Daemon state is canonical; app/extension are projections only.
- Lifecycle, approval, risk, reason-code, and closure evidence fields are parity-locked across surfaces.
- After restart/reconnect, projections must converge to the same actionable pending/terminal state without duplicate submissions.

## Mission Invariants
1. Lifecycle transitions are legal, deterministic, and terminal-safe.
2. Planner contracts are versioned and deterministic for identical inputs.
3. Dispatch/retry/replay never duplicate logical packet/run outcomes.
4. High-risk actions never bypass explicit approval.
5. Reconciliation persists one replay-stable winner with reason code.
6. Closure is always either `completed` or one active approval question.
7. Cross-surface projections preserve canonical reason/risk semantics.

## Out of Scope
- UI visual design details.
- Provider-specific implementation internals beyond adapter contracts.
- Deployment topology beyond local-first daemon canonical runtime.
