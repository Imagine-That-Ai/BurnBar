# Adversarial audit — Android Signal producer changeset (item 3) + fixes

Workflow `wf_507333cb-f6c` (21 agents): 16 findings raised, **7 confirmed** (skeptic-verified), all **FIXED**. The L41 server runtime was audited separately (`wf_0fe94bbd-e65`).

| Sev | Finding (dedup) | Fix |
| --- | --- | --- |
| **major** (×3: cross-platform parity, read-safety, activation) | `atRestRecipients` used `?: continue` on a trusted device with a missing `keyVersion` → **fail-open**: silently excluded that device from the envelope recipients, so it could never decrypt (cross-device read loss). Diverged from iOS (throws) and contradicted its own docstring. `keyVersion` is rules-optional on escrow docs, so the state is reachable. | `?: continue` → `throw IllegalStateException(...)`; also changed the field-validation `require()` → `check()` so every `atRestRecipients` throw is `IllegalStateException` (uniform for producer catch blocks). `AndroidCloudVaultSignalPayloads.kt`. |
| **major** | `scheduleCloudMirror` caught only `IllegalStateException`; a producer/Firestore exception on its `SupervisorJob` IO coroutine (no handler) could crash. | Broadened catch to `Exception` (surfaces via `_lastSyncError`, matching the delete/tombstone coroutines). `AssistantChatHistoryStore.kt`. |
| minor | `publishIfNeeded` returned on `exists()` WITHOUT verifying the stored public key matches the local one — a divergent local identity (prefs wiped, doc survived) would silently break decryption. iOS throws `immutablePublicKeyConflict`. | On `exists()`, `check()` stored `publicKeyData` == local; throw on mismatch. `AndroidSignalIdentityKeyStore.kt`. |
| minor | Android only published the Signal identity lazily (seal-time), so flipping the gate would `atRestRecipients`-throw for any trusted peer that hadn't published yet (activation bootstrap gap). iOS publishes eagerly. | Eager-publish the Signal identity (PUBLIC key only) during escrow `registerSelf`, `runCatching`-wrapped (non-fatal). `AndroidEscrowDeviceRegistry.kt`. **Note: a deliberate production behavior change** — every escrow registration now publishes a public identity key (iOS parity, rules-validated, benign). Does NOT activate sealing (sealingScheme stays default). |
| nit | `publishIfNeeded` TOCTOU: concurrent first-publishers both pass `exists()==false`; the 2nd `set` is an UPDATE → rules `PERMISSION_DENIED` → uncaught throw. | Catch `FirebaseFirestoreException` `PERMISSION_DENIED`; if the doc now exists, return (sibling won the idempotent race). `AndroidSignalIdentityKeyStore.kt`. |

9 findings were refuted by the verify stage (not real / not-a-bug).

Re-verified after fixes: `:app:testDebugUnitTest` BUILD SUCCESSFUL (compile + full unit suite, regression-clean); `verify-signal-activation-parity.sh` still GREEN (no activation flip).

## Net state of the Android producers post-audit
- Fail-CLOSED on any malformed trusted-peer identity (no silent device exclusion) — iOS parity restored.
- Identity publish is immutable-checked, race-safe, and eager (bootstrap-complete before activation).
- Producer errors surface (no IO-coroutine crash).
- Still fully inert in production (gate fail-closed) EXCEPT the deliberate eager identity-publish (benign public key, iOS parity).
