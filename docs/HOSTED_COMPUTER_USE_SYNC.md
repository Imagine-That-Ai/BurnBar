# Hosted Computer Use Sync

Hosted Computer Use Sync is the paid entitlement that unlocks OpenBurnBar Computer Use across Mac and phone surfaces.

## Product IDs

- `com.openburnbar.computerUse.monthly`
- `com.openburnbar.hostedComputerUseSync.monthly`
- `com.openburnbar.proMax.bundle.monthly`
- `com.openburnbar.proMax.monthly`

Either Computer Use or Pro Max entitlement unlocks the Computer Use Firestore write paths and the local capability gate snapshot when active. The `hostedComputerUseSync` and `proMax.monthly` IDs are legacy aliases kept valid for existing receipts.

## Client Contract

The Mac owns the canonical session. Phone and tablet clients mirror a narrow state projection:

- Session id, start time, trust mode, action count, spend, and last denial.
- `control.action.log.entry` timeline rows.
- `control.approval.request` rows that can be approved or rejected from the phone.
- `control.denied` events surfaced as non-fatal status.

Clients never receive raw selectors, typed secrets, screenshots, or full audit-chain descriptors through Firestore.

## Firestore Collections

- `users/{uid}/computer_use_sessions/{sessionId}`
- `users/{uid}/computer_use_actions/{actionId}`
- `users/{uid}/computer_use_quota_usage/{dayKey}`
- `ops/computer_use_budget_status/state/current` (public envelope)
- `ops/computer_use_budget_status/metrics/current` (operator metrics)

Rules enforce active entitlement before client writes. The public budget envelope at `state/current` is readable by signed-in users; operator metrics and rollups remain operator-only (see [ADR 006](architecture/006-budget-envelope-visibility.md)).

## Verification

Run:

```bash
cd firestore-rules-tests
firebase emulators:exec --only firestore --project burnbar-test 'node computer-use.test.js'
```

Expected: `9/9 cases passed`.
