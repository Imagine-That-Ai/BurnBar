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
| `/pricing` | `src/pages/pricing.astro` | Free vs. Cloud (`$4.99/mo`) plus billing FAQ |
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
npm run build  # astro build && build-sitemap.mjs
```

Output goes to `website/dist/`. The build step also produces `dist/sitemap.xml`.

## Verify

```sh
npm run verify
```

Runs:
1. `astro check` — TypeScript and Astro template diagnostics
2. `astro build` — production build, all 12 pages
3. `node scripts/check-links.mjs` — verifies every internal `href` resolves to a built page or a static asset

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

Firebase Hosting predeploy runs `npm --prefix "$RESOURCE_DIR/website" run build`,
so a fresh dist is always produced.

### Connecting the burnbar.ai domain

1. In the Firebase console, open project **burnbar** → Hosting → Add custom domain → enter `burnbar.ai` (and `www.burnbar.ai` as redirect to apex).
2. Verify ownership via the TXT record Firebase displays.
3. Add the two A records Firebase shows to Namecheap → Advanced DNS for `burnbar.ai`.
4. Wait for issuance (Firebase auto-provisions Let's Encrypt SSL — usually 24–48h).

If you need the exact Namecheap clicks or a TXT record copy/paste, ping Alberto.

## Security headers

`firebase.json` already ships a hardened header set on every HTML response:

- `Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`
- `Strict-Transport-Security: max-age=63072000; includeSubDomains; preload`
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options: DENY`
- `Referrer-Policy: strict-origin-when-cross-origin`
- `Permissions-Policy` denies camera, geolocation, mic, payment, USB, etc.

`'unsafe-inline'` for `style-src` is the one concession — Astro scopes
component styles via small inline tags. If you want to remove it, switch all
component `<style>` blocks to external `import "./*.css"` and adjust.

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

MIT — same as the rest of the OpenBurnBar repo. Site content (copy,
illustrations, generated mockups) is the property of Imagine That AI LLC.
