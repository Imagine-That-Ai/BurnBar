I have everything needed. Here is the design brief for my slice.

---

## FINDINGS (evidence map)

**The bug.** `RollbackRequest.Status` in `OpenBurnBarCore/.../Contracts/RollbackContracts.swift:104-109` is a default-`rawValue` `String` enum with cases `pending / inFlight / completed / failed`. So `Status.inFlight.rawValue == "inFlight"` (camelCase) and there is **no `cancelled` case**. Every other side of the contract disagrees:

- **firestore.rules:1650** — `request.resource.data.status in ["pending", "in_flight", "completed", "failed"]` — snake_case, **no `cancelled`**.
- **Android** `RollbackService.kt:75-86` — `Status` token enum `pending / in_flight / completed / failed / cancelled` — snake_case **with `cancelled`**.
- **Repo-wide precedent** — every adjacent status enum uses snake_case `cancelled` (rules lines 711, 856, 1287, 1528).

**Impact (real, not theoretical):**
1. If iOS ever writes `status = inFlight` (camelCase), the rule at 1650 **rejects the write** (value not in allowlist) → permission-denied. iOS encodes status via `request.status.rawValue` at `RollbackService.swift:216`.
2. iOS can **never decode a `cancelled` doc**: `decodeRequest` does `Status(rawValue: statusRaw)` (`RollbackService.swift:180`) and bails (`else return nil`) when the raw value isn't a case — so an Android- or Mac-written `cancelled` request silently disappears from the iOS pending list. Note: cancelled docs are also filtered out of the listener query at `RollbackService.swift:87` (`whereField("status", in: ["pending","in_flight"])`), so this is latent today but becomes live the moment any reader queries terminal states.
3. Cross-platform inconsistency: Android writes/reads `in_flight` + `cancelled`; iOS would write `inFlight` and choke on `cancelled`.

**Who writes status today:** only iOS (`RollbackService.swift:216`) and Android (`RollbackService.kt:262`), and both only ever write `.pending` on submit. There is **no Mac/AgentLens rollback-request writer yet** (grep of `AgentLens` for `rollback_requests`/`RollbackRequest` is empty) — the Mac "claim" path that would transition to `in_flight`/`completed`/`failed`/`cancelled` is unbuilt. **Therefore no production doc with a camelCase `inFlight` status has ever been written** (the only producer that could write it is the unbuilt Mac path; iOS/Android never set anything but pending). The "migrate already-written `inFlight` docs" requirement is satisfied by adding read-side tolerance (defensive), but there is no live corpus to back-fill.

**Existing tests touching this:**
- Core: `HermesSquarePhaseCTests.swift:152-168` (`testRollbackRequestPreservesStatusAndScope`) — only exercises `.pending`.
- Android: `RollbackServiceTest.kt:47-53` (`request_status_tokens_round_trip`) — already iterates all 5 tokens incl. `cancelled`; passes today. No change needed but it documents the expected wire tokens.
- iOS: `RollbackServiceSealTests.swift:32,58` assert `status == "pending"` / `.pending`.

---

## DESIGN BRIEF

Canonical wire value decision: **snake_case**, to match firestore.rules (1650), Android (`RollbackService.kt:75-86`), and every adjacent status enum. Swift moves to explicit snake_case `rawValue`s plus a tolerant decoder for the legacy camelCase `inFlight` value, plus the missing `cancelled` case. The rule gains `cancelled`.

1. **`OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/RollbackContracts.swift:104-109`** — replace the `Status` enum. Give explicit snake_case raw values, add `cancelled`, and add a tolerant `init(from:)`/factory so the legacy `"inFlight"` camelCase value still decodes (do NOT silently map unknowns to pending — only the one known legacy alias). Concretely:
   ```swift
   public enum Status: String, Codable, Sendable, Hashable {
       case pending
       case inFlight = "in_flight"
       case completed
       case failed
       case cancelled

       /// Tolerate the legacy camelCase `"inFlight"` wire value written before
       /// the snake_case migration (privacy-leak-remediation rollback-status-bug).
       public init(from decoder: Decoder) throws {
           let raw = try decoder.singleValueContainer().decode(String.self)
           switch raw {
           case "inFlight": self = .inFlight            // legacy alias
           default:
               guard let value = Status(rawValue: raw) else {
                   throw DecodingError.dataCorrupted(.init(
                       codingPath: decoder.codingPath,
                       debugDescription: "Unknown RollbackRequest.Status \(raw)"))
               }
               self = value
           }
       }
   }
   ```
   `pending`, `completed`, `failed` keep their implicit raw values (already snake-safe single words). `cancelled` serializes as `"cancelled"` (matches Android + rules). The default synthesized `encode(to:)` now emits `"in_flight"`.

2. **`OpenBurnBarMobile/Services/RollbackService.swift:180`** — `decodeRequest` currently does `RollbackRequest.Status(rawValue: statusRaw)`, which bypasses the tolerant `init(from:)` from step 1 (it's the memberwise `rawValue` initializer, not the decoder) and will return nil for both `"cancelled"`-via-rawValue-success-but… actually `cancelled` works via rawValue, but legacy `"inFlight"` would fail. Change the lookup to route through a tolerant resolver so legacy camelCase resolves and unknown stays nil-guarded. Replace:
   ```swift
   let status = RollbackRequest.Status(rawValue: statusRaw)
   ```
   with a tolerant decode that reuses the alias:
   ```swift
   let status = RollbackRequest.Status(wireValue: statusRaw)   // see step 3
   ```
   (keeps the existing `guard let … else { return nil }` so a genuinely unknown status still drops the row).

3. **`OpenBurnBarCore/.../RollbackContracts.swift`** (same enum, add a convenience next to the enum) — add a non-throwing `init?(wireValue:)` used by the Firestore dictionary decoder (which has a raw `String`, not a `Decoder`), so both the `Codable` path (step 1) and the dictionary path (step 2) share one alias table:
   ```swift
   public init?(wireValue: String) {
       if wireValue == "inFlight" { self = .inFlight; return }   // legacy alias
       self.init(rawValue: wireValue)
   }
   ```
   This is the single source of truth for "open a stored status string." `decodeRequest` (step 2) calls `Status(wireValue: statusRaw)`.

4. **`firestore.rules:1650`** — extend the allowlist to include `cancelled` so the Mac claim path (and Android, which already round-trips `cancelled`) can write it. The legacy camelCase `inFlight` is deliberately **not** added — new client/Mac writes must use snake_case `in_flight`; the rule keeps the wire surface clean and only the read decoders tolerate legacy. Change to:
   ```
   && request.resource.data.status in ["pending", "in_flight", "completed", "failed", "cancelled"];
   ```

5. **No change to `OpenBurnBarMobile/Services/RollbackService.swift:87`** (`whereField("status", in: ["pending", "in_flight"])`) and **`RollbackService.kt:169`** (`whereIn("status", listOf("pending", "in_flight"))`) — these intentionally scope the *pending* listener to active states; terminal `completed`/`failed`/`cancelled` are correctly excluded. Leave as-is. (Flag for the Mac-claim slice author: when adding a "resolved requests" view, query the terminal states explicitly.)

6. **No Android change required.** `RollbackService.kt:75-86` already has snake_case tokens + `cancelled`. After step 1, iOS `inFlight.rawValue == "in_flight"` now matches Android's `IN_FLIGHT.token == "in_flight"` byte-for-byte. The `RollbackServiceTest.kt:47-53` token round-trip already passes and now documents the cross-platform contract; no edit.

### Tests (exact change points)

7. **`OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesSquarePhaseCTests.swift`** — extend `HermesSquareRollbackTests` (after line 168) with three cases:
   - `testStatusRawValuesAreSnakeCaseWireTokens`: assert `RollbackRequest.Status.inFlight.rawValue == "in_flight"`, `.cancelled.rawValue == "cancelled"`, `.pending.rawValue == "pending"`, `.completed.rawValue == "completed"`, `.failed.rawValue == "failed"` (locks the wire contract against future camelCase regressions).
   - `testStatusDecodesLegacyCamelCaseInFlight`: `JSONDecoder().decode(RollbackRequest.Status.self, from: Data("\"inFlight\"".utf8)) == .inFlight` and `init(wireValue: "inFlight") == .inFlight`.
   - `testStatusRejectsUnknownWireValue`: `RollbackRequest.Status(wireValue: "bogus") == nil` and the `Codable` path throws on `"bogus"`.
   - Extend `testRollbackRequestPreservesStatusAndScope` (line 152) to also round-trip a `.inFlight` and a `.cancelled` request and assert the encoded JSON string contains `"in_flight"` / `"cancelled"` (not `"inFlight"`).

8. **`OpenBurnBarMobileTests/RollbackServiceSealTests.swift`** — add `test_decodeRequest_legacyCamelCaseInFlightStatus_decodes` mirroring `test_decodeRequest_legacyPlaintextScope_stillDecodes` (line 61) but with `"status": "inFlight"`, asserting `decoded.status == .inFlight`. Add `test_decodeRequest_cancelledStatus_decodes` with `"status": "cancelled"` asserting `decoded.status == .cancelled` (proves the prior nil-bail bug is fixed). Existing assertions at lines 32/58 (`"pending"` / `.pending`) stay valid.

9. **`android/app/src/test/java/com/openburnbar/data/missions/RollbackServiceTest.kt`** — already covers all 5 tokens (lines 47-53). Add one assertion in a new test that `Status.fromToken("inFlight")` (legacy camelCase) falls back to `PENDING` per the existing `fromToken` contract (it does today — `values().firstOrNull { it.token == token } ?: PENDING`), and add an explicit assert `Status.IN_FLIGHT.token == "in_flight"` to lock cross-platform parity with the Swift wire value from step 7. No production Kotlin change.

### Round-trip safety summary
- iOS write → `in_flight`/`cancelled` (snake) → **rule accepts** (step 4) → Android `fromToken` decodes (snake match) ✓; iOS `decodeRequest` via `wireValue` decodes ✓.
- Android write → `in_flight`/`cancelled` (snake) → rule accepts → iOS `decodeRequest` via `wireValue` decodes ✓ (was broken for `cancelled` before).
- Legacy doc (if any) carrying `inFlight` → rule would have rejected it at write time, so none exist server-side, but **read decoders on both platforms tolerate it** defensively (iOS via `wireValue` alias; Android via `fromToken` → falls back to PENDING, acceptable since no such doc exists).

This slice is orthogonal to the gateway-E2EE work and touches no crypto; it can land independently in the companion BurnBar-repo PR.

Relevant files (absolute):
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/RollbackContracts.swift` (enum: 104-109)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobile/Services/RollbackService.swift` (decode: 180; encode: 216; listener filter: 87)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/android/app/src/main/java/com/openburnbar/data/missions/RollbackService.kt` (enum: 75-86 — no change)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/firestore.rules` (allowlist: 1650)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesSquarePhaseCTests.swift` (152-169)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarMobileTests/RollbackServiceSealTests.swift` (43-77)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/android/app/src/test/java/com/openburnbar/data/missions/RollbackServiceTest.kt` (47-53)