Both edits are in place and correct. All changes are confined to my owned files plus the round-trip test in my area. I did not touch `firestore.rules` (B-rules owns the `cancelled` allowlist addition), the Core `HermesSquarePhaseCTests.swift`, the Android files, or the rules test.

## CHANGELOG

**`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/RollbackContracts.swift`** (owned)
- Rewrote `RollbackRequest.Status` (was `pending/inFlight/completed/failed` with default camelCase rawValues, no `cancelled`).
- New explicit snake_case wire token: `case inFlight = "in_flight"`. `pending`/`completed`/`failed` keep implicit single-word rawValues (already snake-safe).
- Added `case cancelled` (serializes as `"cancelled"`, matching Android `IN_FLIGHT.token`/`CANCELLED.token` and the firestore.rules allowlist B-rules is extending).
- Added tolerant `public init(from decoder: Decoder) throws` — maps legacy camelCase `"inFlight"` → `.inFlight`; all other values go through `Status(rawValue:)` and a genuinely-unknown value throws `DecodingError.dataCorrupted` (no silent map-to-pending).
- Added non-throwing `public init?(wireValue: String)` — shares the same single legacy-alias table (`"inFlight"` → `.inFlight`), else `init(rawValue:)`; returns `nil` for unknown so dictionary readers drop the row.
- The synthesized `encode(to:)` is retained (only `init(from:)` was overridden), so encoding emits `"in_flight"`/`"cancelled"`/`"pending"`/etc.

**`OpenBurnBarMobile/Services/RollbackService.swift`** (owned)
- `decodeRequest` (line ~180): replaced `RollbackRequest.Status(rawValue: statusRaw)` with `RollbackRequest.Status(wireValue: statusRaw)`, keeping the existing `guard let … else { return nil }` so legacy `"inFlight"` and `cancelled` now decode while genuinely-unknown statuses still drop the row.
- No change to the listener filter `whereField("status", in: ["pending", "in_flight"])` (line 87) or to `encodeRequest`'s `request.status.rawValue` write (line ~219, now correctly emits `"in_flight"`).

**`OpenBurnBarMobileTests/RollbackServiceSealTests.swift`** (round-trip test in my area — directly exercises my `RollbackService`/`Status`)
- Added `test_encodeRequest_inFlightStatus_encodesSnakeCase_andRoundTrips`: asserts `.inFlight` encodes as wire `"in_flight"` (never camelCase) and round-trips back to `.inFlight`.
- Added `test_decodeRequest_legacyCamelCaseInFlightStatus_decodes`: a doc with `"status": "inFlight"` decodes to `.inFlight` via the `wireValue` alias.
- Added `test_decodeRequest_cancelledStatus_decodes`: a `"status": "cancelled"` doc decodes to `.cancelled` (proves the prior nil-bail/disappearing-row bug is fixed).
- Added `test_decodeRequest_unknownStatus_dropsRow`: `"status": "bogus"` → `decodeRequest` returns `nil`.
- Existing assertions at lines 32/58 (`"pending"`/`.pending`) remain valid (unchanged raw value).

**Cross-stream dependencies (not edited by me, per ownership):**
- **B-rules** must add `"cancelled"` to the `firestore.rules:1650` status allowlist (`["pending","in_flight","completed","failed","cancelled"]`) so Mac/Android `cancelled` writes pass; legacy camelCase `"inFlight"` is deliberately NOT added (write surface stays snake_case; only read decoders tolerate legacy).
- **Core test owner** (`HermesSquarePhaseCTests.swift`) may extend `testRollbackRequestPreservesStatusAndScope` to also round-trip `.inFlight`/`.cancelled` (recon step 7) — that file is outside my ownership. The existing `.pending`-only test there still passes with my enum change (raw value `"pending"` unchanged; custom `init(from:)` handles it via the `default` branch).
- **Android** needs no change: `RollbackService.kt` tokens already `in_flight`/`cancelled`; after this slice iOS `inFlight.rawValue == "in_flight"` matches byte-for-byte.

**Deviations/blockers:** None. No crypto touched (orthogonal to gateway-E2EE). I could not run `swift build`/tests (Swift streams are excluded from local builds per the hard rules; central verify follows).