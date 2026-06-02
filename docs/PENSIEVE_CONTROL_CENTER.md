# Data & Privacy Control Center

"The Pensieve" — a unified, granular, end-to-end-encryption-aware surface where a
member can see, export, control, and delete **every** domain of their data across
web, iOS, iPadOS, macOS, and Android. Built over the Pensieve E2EE backend (see
`docs/PENSIEVE.md`). One coherent design + contract; five surfaces.

## Architecture (one source of truth → five surfaces)

- **Data-domain registry** — `packages/data-domains/registry.json` is the canonical
  map of the ~12 user-facing data domains (encryption tier, server-sees vs.
  device-only, Firestore/Storage paths, callables). Codegen emits typed consts for
  every platform (`gen/domains.ts`, `gen/DataDomains.swift`, `gen/DataDomains.kt`);
  a `driftcheck.mjs` proves every `users/{uid}/` collection in `firestore.rules` is
  registered or explicitly excluded (currently 89 collections, 0 drift).
- **Design tokens** — `packages/design-tokens` (DTCG → Style Dictionary v5) emits
  CSS/Swift/Kotlin from one "Pensieve" token set (obsidian / mercury-silver basin /
  brass keys / frost sealed / wax-crimson destructive; brand fonts Outfit/Geist/
  JetBrains Mono; per-tier badge colors).
- **Callable contract** — every surface binds to the same Cloud Functions (all
  `onCall`, us-central1, App Check, auth-gated): `getDataDomainUsage`,
  `exportUserData`, `deleteDomainData`, `setupRecovery`/`confirmRecovery`/
  `listRecovery`, `revokeAllAccess` (panic), `getAuditLog`/`verifyAuditLog`,
  `registerBrowserEscrowDevice`. The server never sees plaintext or the vault key.

## Status

| Phase | Surface | State | Verification |
|---|---|---|---|
| 0 | Registry + tokens | **Done** | data-domains 7/7, design-tokens 4/4, drift 0/89, CI-gated |
| 1 | Backend callables | **Done + hardened** | functions tsc/eslint clean, vitest 48/48, security-reviewed |
| 2 | Web `app.burnbar.ai` | **Done, builds** | tsc clean, vitest 19/19 (incl. Swift↔TS crypto interop), `next build` ✓ |
| 3 | macOS workbench | **Code-complete; build-wiring pending Xcode** | swiftc -parse clean, dep-existence checked |
| 4 | iOS + iPad + ingestion | **Code-complete; build-wiring pending Xcode** | parse + symbol checks |
| 5 | Android | **Code-complete; build-wiring pending Gradle** | brace/import/detekt review; gen files byte-identical |

The native surfaces (3–5) are authored to the real repo patterns + swiftui-expert
/ M3-Expressive standards and pass syntax/parse + dependency-existence checks, but
**cannot be compiled in the authoring environment** (no Xcode/Gradle). They need
the build-wiring below before they run.

## Native build-wiring (requires Xcode / Gradle)

### Xcode (macOS + iOS) — target membership (blocking)
Add to the relevant app/test targets in `OpenBurnBar.xcodeproj`:
- `packages/data-domains/gen/DataDomains.swift` + `packages/design-tokens/dist/swift/PensieveTokens.swift` → **both** AgentLens (macOS) and OpenBurnBarMobile (iOS) targets (or a shared framework).
- macOS: `AgentLens/Views/Settings/DataControlCenter/*.swift` + `AgentLens/Services/DataControlCenterViewModel.swift` → macOS target.
- iOS: `OpenBurnBarMobile/Views/Control/*.swift`, `OpenBurnBarMobile/Models/DataVaultStore.swift`, `HostedQuotaSubscriptionStore+Ultra.swift` → iOS target; `OpenBurnBarCore/Sources/.../{PensieveVectorCloak,PensieveKnowledgeChunker}.swift` are already in the OpenBurnBarCore package; their tests under `OpenBurnBarCore/Tests`.
- `AgentLens/Services/CloudSync/KnowledgeSyncService.swift` → macOS (+ iOS if syncing there); `OpenBurnBarDaemon/Sources/.../PensieveKnowledgeWatcher.swift` → daemon target.

### macOS registration (additive source edits)
- `SettingsTab.swift`: add `case dataPrivacy` (title "Data & Privacy", icon `lock.shield.fill`).
- `SettingsView.swift` detail switch: `case .dataPrivacy: DataControlCenterView(accountManager: accountManager)`.
- `SettingsManifest.swift` + `SettingsItem.swift`: register the anchor `data.controlCenter.inventory` for search/deep-link.

### iOS registration (additive source edits)
- `YouView.swift`: add `YouRoute.dataVault` (+ `.memory`) cases + an entry row.
- `RootTabView.swift` `.navigationDestination(for: YouRoute.self)`: route the new cases to `DataVaultControlView` / `PensieveMemorySearchView`.
- `SettingsManifest.swift`: register the control-center anchor.
- Daemon launch path: instantiate `PensieveKnowledgeWatcher(roots:vaultKeyProvider:).start()`; the macOS/Catalyst `FunctionsDataVaultService` should drain `~/.openburnbar/pensieve-queue` (the watcher's output) and submit via `commitKnowledgeBatch`.

### Android registration (additive source edits)
- `BurnBarNavHostSections.kt`: register the `control` route (deep link `burnbar://control`).
- `YouViewSections.kt`: add a "Data & Privacy" row → `navController.navigate("control")`.
- Domain deep-link map (in nav): `external_mcp→cloud_store`, `connected_devices/device_trust_keys→paired_mac`, `session_logs/conversations_chat/pensieve→streams`, etc.

## Deploy (external)
- Functions: export already wired in `functions/src/index.ts`; `firebase deploy --only functions`.
- Firestore: `firebase deploy --only firestore:rules,firestore:indexes`.
- Web console: create the Hosting site (`firebase hosting:sites:create app-burnbar`), `firebase target:apply hosting console <site-id>`, add to `.firebaserc`, then `firebase deploy --only hosting:console` (predeploy builds `apps/console`). Set `NEXT_PUBLIC_*` Firebase config + `NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY`.
- App Check: register a **reCAPTCHA Enterprise** web provider for the console origin (App Check is enforced at Firestore; without a web provider the browser is rejected once enforcement is on).

## Documented follow-ups (from the adversarial security review — none are blockers)
1. **Passkey sign-in**: add a `verifyPasskeyAssertion` callable (WebAuthn assertion → Firebase custom token); the console keeps passkey primary with Google/Apple fallback today.
2. **`searchKnowledge` client callable**: iOS memory search + web Pensieve recall need a client analog of the hosted-MCP `burnbar_search_knowledge` ({queryVector[384], modelVersion, limit} → sealed hits).
3. **reCAPTCHA Enterprise server assessment**: `registerBrowserEscrowDevice` length-checks `recaptchaToken` but App Check is the real gate; add a server-side `createAssessment` for true defense-in-depth (or drop the field).
4. **Escrow wrapper field reconciliation**: align `apps/console/app/escrow/page.tsx` (`escrowDeviceId`, `wrappedKeyBase64`) with the actual `cloud_vault_key_wrappers` doc shape returned by `exportUserData(['device_trust_keys'])`.
5. **Escrow source-platform hardening**: optionally require `cloud_vault_key_wrappers` source device `platform != Web` in `firestore.rules` (core defense already holds — a browser cannot self-approve).
6. **Static-export CSP**: the console ships static, so CSP is enforced via Firebase Hosting headers (this doc's deploy section) and uses `script-src 'unsafe-inline'` (a Next static-export constraint); revisit with a server target if a nonce is required.
7. **Seal `cli_sessions` / `mobile_assistant_chats` at rest**: today these are plaintext mirrors, so `conversations_chat` is honestly labeled `server_readable`; sealing them would let it return to `end_to_end`.

## Verification (what was run)
```bash
# Foundations
( cd packages/data-domains && node codegen.mjs && node driftcheck.mjs && node --test )
( cd packages/design-tokens && npm ci && npm test )
# Backend
( cd functions && npx tsc --noEmit && npm run lint && npx vitest run src/__tests__/{dataExport,dataDeletion,recovery,panic,auditLog,webAppCheck,dataDomainUsage}.test.ts )
# Web
( cd apps/console && npm install && npm run typecheck && npm test && npm run build )
# Native: open OpenBurnBar.xcodeproj / android in Gradle after the wiring above.
```
