## Description

<!-- Briefly describe your changes and the problem they solve -->

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] This change requires a documentation update

## Testing

- [ ] Repo-native tests/checks pass for the touched area (`./scripts/test-openburnbar-swift.sh`, retrieval evals, `npm run lint`, `npm run test:ci`, etc.)
- [ ] New tests added for new functionality
- [ ] No regression in existing tests

## Code Quality

- [ ] Code follows project style guidelines
- [ ] TypeScript: `npm run lint` passes with no errors
- [ ] Swift verification was run using the repo's current supported scripts or Xcode/SPM test targets

## Documentation

- [ ] Documentation updated if needed
- [ ] README updated if needed
- [ ] CHANGELOG updated with this change

## Security — Computer Use / Remote / privileged paths

Complete this section for **any** change touching Virtual HID, Remote Unlock, Computer Use, privileged daemons, grants, audit, or supply chain.

### Privileged input & IPC

- [ ] Privileged socket or input-leaf changes use peer code-signature auth + audit events ([`docs/security/PRIVILEGED_SOCKET_AUTH.md`](docs/security/PRIVILEGED_SOCKET_AUTH.md))
- [ ] New `"input"` surface is fail-closed or gated by domain-tagged `CapabilityToken` (Remote Unlock vs Computer Use domains stay separate)
- [ ] Panic/kill paths reach the input leaf via `PrivilegedInputKillSwitch` (flag checked on every dispatch)
- [ ] Kill-switch watchdog LaunchDaemon considered if app-side panic is insufficient alone

### Grants, trust, and formal properties

- [ ] Revoked/expired/failed grants produce **no effect** and emit audit/denial receipts
- [ ] Trust mode never escalates without explicit Mac UI approval (downgrade-only invariant)
- [ ] `ComputerUseSafetyInvariantHarness` / `ComputerUseTrustPanicInvariantTests` updated or still green
- [ ] Red-team / policy unit tests updated (`OpenBurnBarPrivilegedSocketRedTeamProbe`, bridge policy tests)

### Audit & cloud (if applicable)

- [ ] Audit chain entries remain append-only; panic sources recorded on halt
- [ ] High-risk Firestore/CU mutations route through callables with `enforceAppCheck` (not `request.app` in rules)

### Supply chain (release / dependency changes)

- [ ] SBOM + OpenVEX regenerated or CI proves no drift (`scripts/generate-sbom.py`, `scripts/supply-chain/generate-vex.py`)
- [ ] Ecosystem deny checks pass (`scripts/supply-chain/run-ecosystem-deny-checks.sh`)
- [ ] No new empty `catch {}` or silent `try?` on privileged validation/panic paths

### Threat model

- [ ] If attack surface changed, update [`docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md`](docs/security/PRIVILEGED_INPUT_THREAT_MODEL.md) residual-risk table

## Checklist

- [ ] My code follows the contribution guidelines
- [ ] I have performed a self-review of my own code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] My changes generate no new warnings
