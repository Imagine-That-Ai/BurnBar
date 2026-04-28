# Third-Party Notices

OpenBurnBar includes or references a small amount of third-party material.

## Bundled provider and vendor logos

- `AgentLens/Resources/Assets.xcassets/*Logo.imageset/` — bundled provider and model logos used by:
- `AgentLens/Models/AgentProvider.swift` (agent/provider branding)
- `AgentLens/Theme/LLMModelBrand.swift` (model vendor branding)
- `AgentLens/Models/ProviderBrand.swift` (catalog/provider branding)

These images are distributed in-repo and rendered as static bundled assets.

Provider names, logos, and service marks are the property of their respective owners and are used strictly for descriptive identification/compatibility. Use of OpenBurnBar does not imply sponsorship, endorsement, or affiliation by those providers.

If you redistribute a modified build, you are responsible for reviewing any applicable brand/trademark usage requirements of the referenced providers.

## Runtime fallback behavior

When a bundled logo is unavailable, UI components fall back to SF Symbols so the app remains functional without blocking on branding assets.

## Generated SVG assets

- `AgentLens/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.svg`
- `docs/favicon.svg`

These SVGs include embedded comments noting they were created with Arrow by QuiverAI. Keep those attribution comments intact unless the assets are replaced.

## Dependencies

OpenBurnBar depends on third-party packages through Swift Package Manager and npm. Their licenses and notices remain with their upstream projects.

---

## Dependency Risk Assessment

### Critical Fork: GRDB-SQLCipher

- **Source:** `https://github.com/SahebRoy92/GRDB-SQLCipher`
- **Pin:** `exactVersion: 6.29.3`
- **Risk:** Personal fork of upstream GRDB. If the fork becomes unmaintained,
  security patches and Swift version updates may lag.
- **Mitigation:**
  1. Vendor the fork under the `OpenBurnBar` org if the project gains traction.
  2. Upstream SQLCipher changes to official GRDB if API-compatible.
  3. Monitor upstream GRDB releases quarterly.
  4. Pin to a commit hash (not just version tag) for supply-chain security.

### Firebase iOS SDK

- **Source:** `https://github.com/firebase/firebase-ios-sdk`
- **Pin:** `from: "11.0.0"` (semver-compatible)
- **Risk:** Major version upgrades may break Auth or Firestore APIs.
- **Mitigation:** Dependabot watches for updates; the PR harness validates on update.

### Sentry Cocoa

- **Source:** `https://github.com/getsentry/sentry-cocoa`
- **Pin:** `from: "8.0.0"`
- **Risk:** Crash-reporting SDK with native code; version skew may lose symbolication.
- **Mitigation:** Pin to an exact version after validation; upload dSYMs in the release workflow.
