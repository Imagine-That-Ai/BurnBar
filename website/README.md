# OpenBurnBar launch website

The marketing website for OpenBurnBar — `burnbar.ai`.

Static site, no analytics, no third-party fonts loaded remotely, no JavaScript
shipped to users beyond a tiny header script. Built with [Astro](https://astro.build).

## Stack

| Layer | Choice | Why |
|---|---|---|
| Framework | Astro 4 (static) | Best-in-class for marketing; ships ~0 JS by default; CSP-friendly. |
| Language | TypeScript (strict) | Catches data-file drift early. |
| Fonts | `@fontsource-variable/*` | Self-hosted variable fonts (Fraunces, Geist, JetBrains Mono). No remote calls. |
| Hosting | Firebase Hosting | Same Firebase project as the rest of the app. |
| Sitemap | Custom generator (`scripts/build-sitemap.mjs`) | Replaces `@astrojs/sitemap` (buggy in this Astro version). |
| Link check | Custom (`scripts/check-links.mjs`) | Network-free; runs in CI. |

Dark theme by default, ember-and-mercury palette, editorial typography. Tokens
live in `src/styles/tokens.css`; global styles in `src/styles/globals.css`.

## Routes

| Route | Source | Purpose |
|---|---|---|
| `/` | `src/pages/index.astro` | Home — hero, pillars, dashboard mockup, surfaces, Hermes, pricing, trust |
| `/product` | `src/pages/product.astro` | Feature tour grouped by tracking / assistant / control / surfaces / honesty |
| `/providers` | `src/pages/providers.astro` | Full provider matrix, confidence legend, caveats |
| `/pricing` | `src/pages/pricing.astro` | OpenBurnBar Local, BurnBar Cloud, BurnBar Cloud Pro, top-ups, and billing FAQ |
| `/privacy` | `src/pages/privacy.astro` | Three-zone trust model + architecture diagram |
| `/security` | `src/pages/security.astro` | Threat model summary, known limits, release provenance |
| `/benefits` | `src/pages/benefits.astro` | Why OpenBurnBar exists |
| `/download` | `src/pages/download.astro` | macOS DMG link, iOS status, editor extension build, system reqs |
| `/faq` | `src/pages/faq.astro` | 11 canonical answers with FAQ JSON-LD |
| `/404` | `src/pages/404.astro` | Custom not-found |
| `/legal/privacy-policy` | `src/pages/legal/privacy-policy.astro` | Legal privacy text |
| `/legal/terms` | `src/pages/legal/terms.astro` | Legal terms text |

All content data lives in `src/data/`. Edit the data files; rebuild.

## Run locally

```sh
cd website
npm ci
npm run dev    # http://127.0.0.1:4321
```

## Build

```sh
npm run build          # refreshes live router research, then builds
npm run build:offline  # builds from committed data only
```

Output goes to `website/dist/`. The build step also produces `dist/sitemap.xml`.
Use `npm run research` or `npm run build` only when you intentionally want to
refresh `src/data/router-rundown-history/`.

## Verify

```sh
npm run verify
```

Runs:
1. content/copy regression checks
2. `astro check` — TypeScript and Astro template diagnostics
3. `npm run build:offline` — production build from committed data
4. `node scripts/update-csp-hashes.mjs --check` — proves the Firebase marketing CSP has exact hashes for the built inline scripts/styles and no `unsafe-inline`
5. `node scripts/test-trust-copy.mjs` — scans built trust/privacy output for external network references
6. `node scripts/check-links.mjs` — verifies every internal `href` resolves to a built page or a static asset

`npm run verify` is intentionally source-data non-mutating; it rebuilds
`website/dist/`, but it must not refresh router-rundown history.
If a legitimate inline script/style changes, run `npm run build:offline` and
then `npm run csp:update` to refresh `firebase.json` before re-running verify.

For a manual visual pass:

```sh
npm run preview                  # http://127.0.0.1:4322
# then visit /, /product, /providers, /pricing, /privacy, /download, /faq
```

For headless screenshots (macOS, requires Chrome):

```sh
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --headless=new --disable-gpu --no-sandbox \
  --window-size=1440,2400 \
  --screenshot=/tmp/home.png http://127.0.0.1:4322/
```

## Deploy (Firebase Hosting)

The website ships through the `marketing` hosting target on the existing
`burnbar` Firebase project. Configuration lives in the **repo-root**
`firebase.json` and `.firebaserc`.

```sh
# from repo root
firebase login            # if not already
firebase deploy --only hosting:marketing
```

Firebase Hosting predeploy runs `npm --prefix website run verify`, so deploys
rebuild the site, run copy/build checks, scan the built trust/privacy output for
external network references, and verify links before publishing.

### Connecting the burnbar.ai domain

1. In the Firebase console, open project **burnbar** → Hosting → Add custom domain → enter `burnbar.ai` (and `www.burnbar.ai` as redirect to apex).
2. Verify ownership via the TXT record Firebase displays.
3. Add the two A records Firebase shows to Namecheap → Advanced DNS for `burnbar.ai`.
4. Wait for issuance (Firebase auto-provisions Let's Encrypt SSL — usually 24–48h).

If you need the exact Namecheap clicks or a TXT record copy/paste, ping Alberto.

## Security headers

`firebase.json` ships route-specific hardened headers. Marketing pages use a
hash-based CSP with `unsafe-inline` absent, while auth/link routes allow the
Firebase/Google endpoints they need:

- `Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self'; style-src-elem 'self' <hashes>; style-src-attr 'unsafe-hashes' <hashes>; script-src 'self' <hashes>; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`
- `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy` denies camera, geolocation, mic, payment, USB, etc.

Run `npm run csp:update --prefix website` after copy or component changes, then
`npm run csp:check --prefix website` to verify the hashes.

## Data files

Single source of truth for site copy lives in `src/data/`:

- `site.ts` — brand, version, URLs, IAP price, status strings, nav
- `providers.ts` — provider matrix (primary + detection-only), confidence labels
- `surfaces.ts` — what ships where (macOS, iOS, editor, daemon, CLI, …)
- `features.ts` — feature copy grouped by category
- `faq.ts` — FAQ Q&A pairs, used to build the FAQ page and JSON-LD

If a fact changes upstream (new provider, new price, new release tag), edit the
matching data file. Pages re-render automatically.

## Open confirmations

See `CLAIMS.md` for the full claim → source matrix and the items that still
need Alberto's sign-off before going live.

## License

OpenBurnBar code is `AGPL-3.0-only`, same as the rest of the repo. Site content
(copy, illustrations, generated mockups) is the property of Imagine That AI LLC.
