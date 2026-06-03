I now have the complete picture. Let me do one final check to confirm whether `personas` would be written as a nested array of maps (which `hasOnly` cannot recurse into) — this affects how the allowlist + sealing must be structured. And confirm the iOS registry persists only to UserDefaults (no cloud), proving the "Phase A/B" cloud writer is unbuilt.

The registry persists user installs to UserDefaults only (`AgentIdentityRegistry.swift:288`), and `updatePersonas`/`install` never touch Firestore. Confirmed: the rule is forward-looking with no live writer.

I have everything needed for the design brief.

## DESIGN BRIEF

### Surface: `users/{uid}/agent_identities/{identityId}`

**Verdict up front:** This surface has **no live writer, no reader, and no Cloud Function** on any platform today. The firestore.rules block (`firestore.rules:1668-1673`) is a **forward-looking, denylist-free hole**: it permits any signed-in owner to write up to 24 arbitrary keys with zero field allowlist — so when the Hermes Square "Phase A/B" cloud-sync writer ships (the rule comment promises "Phone-only writes… cloud copy survives re-install"), it would freely persist plaintext persona/identity free-text. The fix hardens the rule **now** (strict `hasOnly` + seal the free-text), defining the contract before the writer exists, exactly mirroring the project_memory_snapshots forward-write rule from CONTRACT §2.

---

**(1) WRITERS + exact field set.** No Firestore writer exists. The only persistence is iOS `AgentIdentityRegistry` → **UserDefaults**, key `"square.installedManifests.v1"` (`OpenBurnBarMobile/Services/AgentIdentityRegistry.swift:37,279-293`); `install()` (:229), `updatePersonas()` (:256), `uninstall()` (:246) all mutate the in-memory `identities` array + UserDefaults only — never Firestore. Android `AgentIdentityRegistry.kt` mirrors this (local only). The **field set a Phase-A/B writer would send** is the `AgentIdentity` Codable shape (`OpenBurnBarCore/.../SharedModels/AgentIdentity.swift:30-119`) with nested `personas: [AgentPersona]` (`AgentPersona.swift:17-89`):

- Identity top-level (15 keys): `id`, `runtimeID`, `displayName` 🔒, `glyph`, `paletteHex`, `tier`, `availability`, `installSource` (nested map: `kind`,`manifestURL`,`uid`,`catalogID`), `capabilities` (`rawValue`), `dispatchTransport` (nested: `kind`,`runtime`,`endpoint` 🔒,`url` 🔒), `personas` (array of maps), `lastSevenDays` (stats map), `lastRefreshedAt`, `tagline` 🔒.
- Persona per element (12 keys): `id`, `name` 🔒, `description` 🔒, `systemPromptAdditions` 🔒, `permittedTools`, `permittedFileGlobs` 🔒 (leaks local paths), `permittedShellPrefixes` 🔒 (leaks local commands), `permitShell`, `permitFileEdits`, `temperatureOverride`, `preferredModel`, `isDefault`.

🔒 = private free-text to seal: identity `displayName`, `tagline`, transport `endpoint`/`url`; persona `name`, `description`, `systemPromptAdditions`, `permittedFileGlobs`, `permittedShellPrefixes`.

**(2) READERS.** None from Firestore. iOS readers are all in-memory off `AgentIdentityRegistry.shared` (HermesSquare views, brand zone, dispatcher); Android same. When the cloud-sync reader ships it will hold the vault key (see 4).

**(3) SERVER-READ REQUIREMENT — verdict: NONE.** `grep` over `functions/src` returns zero references to `agent_identities`, `persona`, or any identity field except `personaScopeJSON`/`personaID` in `functions/src/types/legacy.ts:3070-3071` — and those belong to the **separate** `cli_agent_mission_requests` surface (the dispatch-time scope payload), not this collection. No Cloud Function reads, matches, routes, or indexes any agent_identities field. Per the crypto-primitives recon (§2: "Cloud Functions are pure store-and-forward / opaque-index… server has zero need for plaintext → seal everything"). **This is pure store-and-forward between the user's own devices → seal with the vault key; no keyed-hash needed.**

**(4) VAULT-KEY AVAILABILITY.** Every prospective reader/writer is a native device that holds the key: iOS/Mac via `CloudVaultKeyStore` (Keychain), Android via `AndroidCloudVaultKeyAccess`. The server is the only non-key-holder and is never a reader here. Sealing is unconditionally safe.

**(5) firestore.rules — current vs. exact change.**

CURRENT (`firestore.rules:1668-1673`):
```
match /users/{userId}/agent_identities/{identityId} {
  allow read: if ownsUserNamespace(userId);
  allow create, update: if ownerWritableNonSecret(userId)
    && request.resource.data.keys().size() <= 24;
  allow delete: if ownsUserNamespace(userId);
}
```
REPLACE the create/update with a strict `hasOnly` allowlist that (a) drops the plaintext free-text keys in favor of `sealedX`, (b) keeps non-private metadata plaintext, (c) reuses `validCloudSealedText` + `rejectsPlaintextWhenSealed` (defined `:449`, `:1013`). Note: Firestore rules `hasOnly` only constrains top-level keys (cannot recurse into the `personas[]` element maps), so seal the per-persona free-text into a **single top-level `sealedPersonas`** `CloudVaultSealedText` envelope (the whole `personas` array JSON sealed) and keep only non-private persona scaffolding if needed top-level — mirroring how CONTRACT §7 reseals whole records (`CLIAgentSessionCodec.encodeSealed`). Exact block:
```
match /users/{userId}/agent_identities/{identityId} {
  allow read: if ownsUserNamespace(userId);
  allow create, update: if ownerWritableNonSecret(userId)
    && request.resource.data.keys().hasOnly([
      "id", "runtimeID", "glyph", "paletteHex", "tier", "availability",
      "installSource", "capabilities", "dispatchTransport",
      "lastSevenDays", "lastRefreshedAt",
      "sealedDisplayName", "sealedTagline", "sealedPersonas", "updatedAt"
    ])
    && rejectsPlaintextWhenSealed("displayName", "sealedDisplayName")
    && rejectsPlaintextWhenSealed("tagline", "sealedTagline")
    && rejectsPlaintextWhenSealed("personas", "sealedPersonas")
    && (!("sealedDisplayName" in request.resource.data) || validCloudSealedText(request.resource.data.sealedDisplayName))
    && (!("sealedTagline" in request.resource.data) || validCloudSealedText(request.resource.data.sealedTagline))
    && (!("sealedPersonas" in request.resource.data) || validCloudSealedText(request.resource.data.sealedPersonas))
    && !("displayName" in request.resource.data)
    && !("tagline" in request.resource.data)
    && !("personas" in request.resource.data);
  allow delete: if ownsUserNamespace(userId);
}
```
(The trailing three plaintext denials are stricter than `rejectsPlaintextWhenSealed` because no legacy plaintext docs exist for this never-written collection — there is nothing to migrate, so reject cleartext outright. The `dispatchTransport.endpoint`/`url` free-text stays nested and is bounded by `ownerWritableNonSecret`'s size limits; if exposing third-party endpoints is undesirable, seal `dispatchTransport` likewise — flag as optional hardening.) `ownerWritableNonSecret` already runs `requestWithinBasicLimits()` + `hasNoPlaintextSecretFields()`, so the explicit `size() <= 24` is subsumed.

**(6) REGISTRY OWNER + honesty edit.** `agent_identities` is currently listed under `registry.json:243` `excludedCollections` ("Local agent identity config.") — which is **honest only while there is no cloud writer**. The honest edit: keep it excluded **and** make the exclusion note state the cloud copy is sealed once Phase A/B ships, OR (preferred, since the rule already provisions a cloud doc) promote it into the **`pensieve`/agent-config domain** as a `deviceOnly` surface. Minimum honesty edit now: change `:243` to `"agent_identities": "Local agent identity config; any cloud-synced copy seals persona/identity free-text (displayName, tagline, personas) — server stores only opaque sealed envelopes + non-private metadata."` No `serverSees` plaintext claim is introduced because the server sees none. (No `codegen.mjs`/`syncGeneratedSources` regen needed unless promoted out of `excludedCollections`.)

**(7) TESTS TO ADD** (`functions/scripts/test-firestore-rules.mjs`, mirroring T12 at :3110 and using the `sealedText()` helper at :134):
- **T-AI-a (sealed accepted):** `setDoc(users/ai-owner/agent_identities/x, { id, runtimeID:"claude", glyph, paletteHex, tier:"service", availability:"online", sealedDisplayName: sealedText(), sealedTagline: sealedText(), sealedPersonas: sealedText() })` → `assertSucceeds`.
- **T-AI-b (plaintext rejected):** same doc but with `displayName:"My Claude"` (or `tagline`, or `personas:[{...}]`) present → `assertFails` (proves the cleartext denial + `rejectsPlaintextWhenSealed`).
- **T-AI-c (unlisted key rejected by hasOnly):** add `{ ..., notes:"hi" }` → `assertFails`.
- **T-AI-d (malformed sealed envelope rejected):** `sealedDisplayName: { algorithm:"rot13" }` → `assertFails` (`validCloudSealedText`).
- Swift round-trip: extend `CloudVaultCryptoTests` to seal/open an `AgentIdentity`'s `displayName`/`tagline` and a JSON-encoded `personas` array via `CloudVaultCrypto.sealText`/`openText` with legacy plaintext fallback; mirror in Android `CloudVaultCryptoTest.kt`. Add a decoder unit test asserting the reader falls back to plaintext `displayName`/`personas` when `sealedX` is absent (forward-compat, even though no legacy docs exist).

---

## DESIGN BRIEF — copy-pasteable change points

1. **firestore.rules:1668-1673** — replace the create/update rule with the strict `hasOnly` allowlist block in (5): allowlist = `[id, runtimeID, glyph, paletteHex, tier, availability, installSource, capabilities, dispatchTransport, lastSevenDays, lastRefreshedAt, sealedDisplayName, sealedTagline, sealedPersonas, updatedAt]`; add `rejectsPlaintextWhenSealed` for `displayName→sealedDisplayName`, `tagline→sealedTagline`, `personas→sealedPersonas`; add `validCloudSealedText` on each sealed field; add outright `!("displayName"/"tagline"/"personas" in …)` denials (no legacy migration window). Reuses existing helpers at `firestore.rules:449,1013,71`.
2. **Sealed shape** — `sealedDisplayName`, `sealedTagline`, `sealedPersonas` are each `CloudVaultSealedText` (`{algorithm,keyVersion,nonce,ciphertext,tag}`). `sealedPersonas` = `CloudVaultCrypto.sealText(JSON(personas[]))` because rules `hasOnly` cannot recurse into the persona element maps to seal `name`/`description`/`systemPromptAdditions`/`permittedFileGlobs`/`permittedShellPrefixes` individually. Server validates via `requireSealedText` (`functions/src/callables/shared.ts:338`) if a callable is ever added (none today).
3. **Writer (future Phase A/B sync, iOS `AgentIdentityRegistry`)** — when added, seal with `CloudVaultCrypto.sealText(displayName,…)`, `sealText(tagline,…)`, `sealText(JSONEncoder().encode(personas),…)`; never send plaintext `displayName`/`tagline`/`personas`. Android mirror in `android/.../data/square/AgentIdentityRegistry.kt`.
4. **Reader (future)** — open `sealedX` with the vault key; legacy plaintext fallback (read `displayName`/`tagline`/`personas` if `sealedX` absent), even though no legacy docs exist, to match the contract's universal decoder rule.
5. **registry.json:243** — update the `excludedCollections` note to state the cloud-synced copy seals persona/identity free-text and the server sees only opaque sealed envelopes + non-private metadata (no `serverSees` plaintext claim introduced).
6. **Tests** — add T-AI-a…d in `functions/scripts/test-firestore-rules.mjs` (mirror T12 at :3110, helper `sealedText()` :134) + Swift/Kotlin `CloudVaultCrypto` round-trip and plaintext-fallback decoder tests.

**SERVER-READ VERDICT: none.** No Cloud Function reads any agent_identities field for matching/routing/indexing (zero `functions/src` references; `personaScopeJSON`/`personaID` at `legacy.ts:3070-3071` belong to the separate mission-request surface). Pure device-to-device store-and-forward → **SEAL with the vault key (`sealedDisplayName`/`sealedTagline`/`sealedPersonas`)**; no keyed-hash required.