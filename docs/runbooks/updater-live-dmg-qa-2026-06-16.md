# Updater Live DMG QA - 2026-06-16

## Scope

Validate the direct-download macOS update/install surface against the live GitHub Release channel without modifying the newer local `/Applications/OpenBurnBar.app` install.

## Live Channel

- Repository: `Imagine-That-Ai/BurnBar`
- Latest release: `v0.1.2-beta.1`
- Published: `2026-04-13T12:38:07Z`
- Assets present:
  - `OpenBurnBar-0.1.2-beta.1-macOS.dmg`
  - `OpenBurnBar-0.1.2-beta.1-macOS.zip`
- Assets missing:
  - `latest-macos.json`
  - `appcast.xml`

## Local Install Baseline

- Installed app: `/Applications/OpenBurnBar.app`
- Version: `1.0.2`
- Build: `42`
- Bundle ID: `com.openburnbar.app`

The live release DMG contains version `0.1.2-beta`, build `1`, so the in-app installer's anti-downgrade gate should reject it even if the feed were present.

## Evidence

### Feed And Appcast

```bash
curl -fsSIL --max-time 30 \
  https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json
```

Result: `404` after redirect to `v0.1.2-beta.1/latest-macos.json`.

```bash
curl -fsSIL --max-time 30 \
  https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml
```

Result: `404` after redirect to `v0.1.2-beta.1/appcast.xml`.

### DMG Download And Digest

```bash
gh release download v0.1.2-beta.1 \
  --repo Imagine-That-Ai/BurnBar \
  --pattern 'OpenBurnBar-0.1.2-beta.1-macOS.dmg' \
  --dir /tmp/openburnbar-release-download-test

shasum -a 256 /tmp/openburnbar-release-download-test/OpenBurnBar-0.1.2-beta.1-macOS.dmg
```

Result:

```text
c82920a3fbf572d9108ea23b45037be973df7e7abbd7c0297d349a3349179afa
```

This matches the release asset digest reported by GitHub.

### Notarization / Gatekeeper

```bash
spctl --assess --type open --verbose=4 \
  /tmp/openburnbar-release-download-test/OpenBurnBar-0.1.2-beta.1-macOS.dmg

xcrun stapler validate \
  /tmp/openburnbar-release-download-test/OpenBurnBar-0.1.2-beta.1-macOS.dmg
```

Results:

```text
rejected
source=Insufficient Context
OpenBurnBar-0.1.2-beta.1-macOS.dmg does not have a ticket stapled to it.
```

### Mounted App Signature

```bash
hdiutil attach -nobrowse -noautoopen -readonly -plist \
  /tmp/openburnbar-release-download-test/OpenBurnBar-0.1.2-beta.1-macOS.dmg

codesign --verify --deep --strict --verbose=4 \
  /Volumes/OpenBurnBar/OpenBurnBar.app
```

Result:

```text
/Volumes/OpenBurnBar/OpenBurnBar.app: code object is not signed at all
```

## Verdict

Fail. The live direct-download channel cannot currently prove the one-click update/install/relaunch path:

1. The app's configured update feed `latest-macos.json` is missing from the latest release.
2. The Sparkle appcast `appcast.xml` is missing from the latest release.
3. The latest public DMG has no stapled notarization ticket.
4. The app inside the latest public DMG is unsigned.
5. The latest public DMG is older than the currently installed local app, so the anti-downgrade gate should refuse it.

## Release Gate

Before marking updater live QA complete, publish a fresh release that includes:

- signed and notarized Developer ID `OpenBurnBar.app`;
- stapled DMG ticket;
- `latest-macos.json` with `sha256`, `length`, and non-empty `sparkleEdSignature`;
- `appcast.xml` with matching Sparkle EdDSA signature;
- a build number strictly greater than the installed baseline used for QA;
- a live install test proving download -> verify -> mount -> swap -> relaunch.
