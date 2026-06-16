# Open Questions

## Product Decisions Required

### OQ-001: CloudVault first-vault server mediation
**Question:** Should first-vault creation and rotation require server-mediated survivor quorum?
**Context:** Currently any single trusted device can create or rotate the vault key. The server enforces monotonic generation but does not require quorum.
**Options:** (a) Accept current design (single-device trust), (b) Require server-mediated first-vault, (c) Require survivor quorum for rotation
**Risk if unresolved:** Single compromised trusted device could rotate vault key and lock out other devices
**Owner:** Founders/security lead

### OQ-002: iroh first-contact safety-number default
**Question:** Should safety-number comparison be default-on before product-wide T-TRN-01 closure?
**Context:** Key-change pinning is active, but first-contact verification requires manual safety-number compare which is not default-on.
**Options:** (a) Accept current (key-change pinning + staged UI), (b) Make safety-number compare default-on
**Risk if unresolved:** Relay operator could MITM first pairing without user detection
**Owner:** Product/security lead

### OQ-003: CLI executable provenance UX
**Question:** What trust UX should govern user-installed CLI binaries (npm/bun/shim)?
**Context:** Strict first-party codesign validation would break common agent CLI installs.
**Options:** (a) Accept current (same-user boundary, no signing), (b) Implement trust-store with explicit approval, (c) Warn on unsigned CLI
**Risk if unresolved:** Same-user attacker can replace CLI with malicious shim
**Owner:** Product/security lead

### OQ-004: App Check attestation max-age
**Question:** What max-age is acceptable for high-risk callable attestation?
**Context:** Currently 30 days. Tighter is safer but requires more frequent re-attestation.
**Options:** (a) Keep 30 days, (b) Tighten to 7 days, (c) Make Remote Config configurable
**Risk if unresolved:** Stolen device retains high-risk access for up to 30 days
**Owner:** Security lead

### OQ-005: Stable push routing IDs
**Question:** Are stable APNs/FCM routing IDs accepted metadata, or should they rotate per session?
**Context:** Push payloads carry stable routing IDs necessary for delivery. Display names and control fields are scrubbed.
**Options:** (a) Accept stable IDs, (b) Rotate per session (may affect delivery reliability)
**Risk if unresolved:** Push providers can correlate call patterns
**Owner:** Product lead

### OQ-006: Git history purge for committed evidence (M-004)
**Question:** Should git history be purged for the previously committed security evidence file?
**Context:** Evidence file removed from current tree, but history may retain GCP owner email and IAM inventory.
**Options:** (a) Purge history (rewrite + force push), (b) Accept and rotate exposed identifiers, (c) Accept as low-risk
**Risk if unresolved:** Prior exposure of GCP metadata in git history
**Owner:** Security lead

### OQ-007: Branch protection enforcement
**Question:** Should `verify-github-governance.sh` be a required PR check?
**Context:** Branch protection on main is documented and verifier exists, but is not yet a required check. The repo is solo-operator.
**Options:** (a) Enable as required check, (b) Accept solo-operator model, (c) Enable when second operator joins
**Risk if unresolved:** Direct pushes could theoretically bypass security CI
**Owner:** Operations lead

### OQ-008: Commit hash for external audit reference
**Question:** What commit hash will be the external-audit reference point?
**Context:** The audit package and remediation need to be tied to a specific, recoverable commit.
**Options:** Tag the current head after fixes land
**Owner:** Release manager
