# privacy: .public log audit

Tracked 2026-09-13. Production Swift `privacy: .public` interpolations must not
include identifiers that can join a user to a remote session (storeKey,
connectionID, bootToken, raw UIDs).

Command:

```
rg -n "privacy: \\.public" AgentLens OpenBurnBarMobile OpenBurnBarDaemon OpenBurnBarCore/Sources --glob '*.swift'
```

Remediation: switch session identifiers to `privacy: .private` unless the field
is an enumerated error class. This file is the Phase 4 register; shrinking the
rg count is the ratchet (`scripts/debt/check-privacy-public-budget.sh`).
