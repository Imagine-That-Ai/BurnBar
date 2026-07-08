# Switcher profile storage (Windows)

The account-switcher surface is backed by an **encrypted, Mac-byte-compatible**
SQLCipher store — `SwitcherSampleData` is now only a dev-host convenience, never
the production backing.

## Layers

| Piece | File | Role |
| --- | --- | --- |
| Contract | `SwitcherProfileStore.cs` (`ISwitcherProfileStore`) | CRUD + active/drain state, ported 1:1 from the macOS `SwitcherProfileStore.swift`. |
| In-memory | `SwitcherProfileStore.cs` (`InMemorySwitcherProfileStore`) | View-model/test fixture; explicit list order == `sortKey`. |
| Real store | `SqlCipherSwitcherProfileStore.cs` | Encrypted backing; maps records ↔ `SwitcherProfileRow` and delegates persistence to the seam. |
| Storage seam | `../../../storage/OpenBurnBar.Storage/SwitcherProfileWriteSeam.cs` | Parameterised SQL over `switcher_profiles` + `switcher_active_profile`. |
| Wiring | `../../OpenBurnBar.App/Storage/WindowsStorageDevHost.cs` (`CreateSwitcherProfileStore`) | Prefer-real-then-fallback (mirrors Budget/ElderWand/SessionLogs). |
| Dev seed | `SwitcherSampleData.cs` | Only used when there are no SQLCipher credentials **and** `OPENBURNBAR_SAMPLE_MODE=1`. |

## Schema (byte-compatible with the Mac DB)

`switcher_profiles` (GRDB migration `v32_switcher_profiles`):
`id` (PK), `targetKind`, `browserType`, `browserMetadataJSON`, `cliType`,
`cliMetadataJSON`, `sortKey`, `createdAt`, `updatedAt`.

`switcher_active_profile` (`v32` + `v46_drain_target_per_provider`):
`activeProfileID`, `updatedAt`, `providerID`. `providerID IS NULL` is the single
global pointer; non-null rows are per-provider drain targets.

Timestamps are stored as ISO-8601 `yyyy-MM-ddTHH:mm:ss.fffffffZ` text
(`StorageDateCodec`), matching the Mac `ORDER BY COALESCE(updatedAt, '1970-01-01T00:00:00Z')`
oracle. Metadata JSON is camelCase, decodable by the Swift `Codable` structs.

## Prefer-real-then-fallback

`CreateSwitcherProfileStore()` returns the real `SqlCipherSwitcherProfileStore`
whenever `OPENBURNBAR_SQLCIPHER_PATH` + `OPENBURNBAR_SQLCIPHER_PASSPHRASE` resolve
to an openable DB. Missing/invalid credentials fall back to an empty in-memory
store — or the `SwitcherSampleData` seed only when `OPENBURNBAR_SAMPLE_MODE=1`.
The real store wins even in sample mode.

## Tests

- `storage/OpenBurnBar.Storage.Tests/SwitcherProfileWriteSeamRoundTripTests.cs` —
  seam CRUD round-trips against the committed byte-compat fixture, schema
  faithfulness (exact column set), and schema-hash / migration-marker /
  `user_version` preservation (reopenable on Mac).
- `tests/presentation/Switcher/SqlCipherSwitcherProfileStoreTests.cs` — the store's
  record ↔ row mapping, enum raw-value parity, active + drain targets, reorder,
  delete, normalized-name uniqueness, and Mac-readable JSON keys.
- `tests/storage/WindowsStorageDevHostRuntimeTests.cs` — prefer-real-over-sample
  wiring, sample-mode gating, and graceful fallback on an unopenable DB.
