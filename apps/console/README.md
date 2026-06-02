# BurnBar Console — `app.burnbar.ai`

The member **Data & Privacy Control Center**. A standalone Next.js 15 (App Router,
React 19) app — independent of the repo's other subprojects, like `website/`.

> Your data, your keys. The server never sees your sealed content.

## What's here

- **The Basin** (`/`) — a Canvas hero rendering your data footprint as swirling
  mercury, one eddy per registry domain, sized by `getDataDomainUsage`, tinted by
  encryption tier. Reduced-motion renders a single static frame.
- **Transparency Inventory** (`/inventory`) — one row per registry domain with a
  tier badge, the **yours ↔ server view-flip** (server side frosts the content),
  count/size, retention, and view/export/delete actions.
- **Pensieve dashboard** (`/pensieve`) — the exemplar domain: quota meters vs the
  tier limits from `getDataDomainUsage().limits.pensieve`, connect-repo, sync-now.
- **Device trust** (`/escrow`) — the browser escrow flow (register → approve on a
  trusted native device → unwrap the vault key in memory → decrypt sealed content).
- **Panic** (header) — `revokeAllAccess` across MCP / devices / escrow / providers.

## Source-of-truth bindings (no hardcoding)

- **Data domains** come from `packages/data-domains/registry.json` via the generated
  `gen/domains.ts`. `scripts/sync-domains.mjs` copies it to `lib/domains.generated.ts`
  on every `predev`/`prebuild`/`pretest`. Never hand-edit the domain list.
- **Design tokens** come from `packages/design-tokens/dist/css/pensieve.css`, synced
  to `styles/pensieve.tokens.css` and mapped into Tailwind via CSS `var()` — no hex.

## Crypto — `lib/escrow.ts`

P-256 ECDH + HKDF-SHA256 (`info="OpenBurnBar-Escrow-v1"`) + AES-256-GCM, **wire-
compatible** with `OpenBurnBarCore/.../CloudVaultCrypto.swift`:

- Wrapped vault key = `ephemeralPub.x963 (65) ‖ nonce (12) ‖ ciphertext ‖ tag (16)`.
- Blob envelope = `{ schemaVersion, algorithm, keyVersion, plaintextSHA256, sealedBoxBase64 }`.
- Sealed text = `{ algorithm, keyVersion, nonce, ciphertext, tag }` (base64 facets).

The browser device key is a **non-extractable** P-256 `CryptoKey` in IndexedDB; the
unwrapped vault key lives only in memory. WebAuthn PRF can additionally gate it.

Cross-language proof: `test/interop/seal.swift` (real CryptoKit) emits a fixture that
`test/interop.test.ts` opens with `lib/escrow.ts` — a Swift-wrapped key unwraps in JS
and Swift-sealed content decrypts in JS. Regenerate with:

```sh
swift test/interop/seal.swift > test/interop/swift-fixture.json
```

## Develop / verify

```sh
npm install
cp .env.example .env.local   # fill NEXT_PUBLIC_FIREBASE_* + reCAPTCHA Enterprise key
npm run dev                  # http://localhost:3000 (uses Firebase emulators in dev)

npx tsc --noEmit             # typecheck
npm run build                # static export to out/
npm test                     # vitest: crypto round-trips, ECDH, Swift interop, registry binding
```

Security: strict CSP, `noindex`/`X-Robots-Tag`, `frame-ancestors 'none'`, App Check
enforced on every callable. The console is private — never indexed.
