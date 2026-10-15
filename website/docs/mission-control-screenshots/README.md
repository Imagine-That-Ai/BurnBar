# Afar page screenshots

Review evidence for the Afar product page (formerly Mission Control). Captured with
Playwright (Chromium) against a local static server that sends the production
marketing CSP, from `npm run build:offline` on 2026-10-15.
These are images of the built page, not of a deployed site, and not of the
native app: the control room on the page is an interactive concept. The Afar logo
in them is the owner's official artwork (see `website/brand/afar/import-receipt.json`).

| File | Viewport | Theme |
| --- | --- | --- |
| `desktop-1440-dark-hero.jpg` | 1440×900 | dark |
| `desktop-1440-light-hero.jpg` | 1440×900 | light |
| `desktop-1440-dark-control-room.jpg` | 1440×900, element | dark |
| `desktop-1440-dark-release-pending.jpg` | 1440×900, element | dark |
| `tablet-834-light-control-room.jpg` | 834×1194 @2x, element | light |
| `phone-390-portrait-dark-hero.jpg` | 390×844 @2x | dark |
| `phone-390-portrait-dark-control-room.jpg` | 390×844 @2x, element | dark |
| `phone-390-portrait-light-control-room.jpg` | 390×844 @2x, element | light |
| `phone-844-landscape-dark-control-room.jpg` | 844×390 @2x, element | dark |
| `phone-844-landscape-light-hero.jpg` | 844×390 @2x | light |
| `fixture-verified-release-NOT-REAL.jpg` | 1440×900, element | dark |

`fixture-verified-release-NOT-REAL.jpg` shows how the release card renders when
the manifest carries full evidence. It was produced from a temporary, uncommitted
manifest with placeholder `example.com` URLs and a dummy checksum (the same fixture
as `website/test/mission-control.test.ts`). It is not a real release.
