# OpenBurnBar Windows update feed

The update-feed format for the Windows auto-updater (Phase 5 · W10 · **R19**). It
mirrors the shipped macOS Sparkle feed
([`scripts/generate-macos-appcast.mjs`](../../../../scripts/generate-macos-appcast.mjs)):
an **Ed25519-signed appcast** plus a JSON companion, verified client-side against
a **pinned public key that is independent of the Authenticode signing
certificate**.

## Files

| File | Role |
|------|------|
| [`appcast-windows.xml`](appcast-windows.xml) | The Sparkle/WinSparkle appcast (RSS 2.0 + `sparkle:` namespace). The `<enclosure>` carries `url` / `length` / `type` / `sparkle:sha256` / `sparkle:edSignature`. WinSparkle 0.8+ verifies `sparkle:edSignature` natively against the pinned EdDSA key. |
| [`latest-windows.json`](latest-windows.json) | The JSON companion (mirror of `latest-macos.json`): `version` / `build` / `downloadUrl` / `length` / `sha256` / `edSignature` / `critical` / `channel` / `minimumSystemVersion` / `releaseNotesUrl`. Drives the direct-download JSON channel + the custom in-app updater. |
| [`pinned-update-key.pub`](pinned-update-key.pub) | The base64 raw (32-byte) Ed25519 **public** key the client pins. **This one is the throwaway DEV/sample pin**; the production pin is injected at build time from the W0 secret. |
| [`sample-artifact.txt`](sample-artifact.txt) | A deterministic stand-in for the installer artifact so the committed sample feed carries a **real** signature + SHA-256 over concrete bytes. |

## What the Ed25519 signature covers (the R19 crux)

`sparkle:edSignature` / `edSignature` is a base64 Ed25519 (RFC 8032) signature
over a canonical descriptor that binds the advertised version, build, download URL, length, SHA-256, critical flag, channel, minimum system version, and release-notes URL.
The client
([`OpenBurnBar.Updater.Core`](../OpenBurnBar.Updater.Core)) refuses to install
unless, in order:

1. the feed parses,
2. its version is dotted-numeric and **strictly newer** than the installed build
   (older ⇒ **downgrade-blocked**; equal ⇒ up-to-date),
3. the downloaded artifact's **byte length** matches,
4. its **SHA-256** matches, and
5. the feed's **Ed25519 signature verifies against the pinned key** over that canonical descriptor.

The pinned key is **independent of the Authenticode certificate**. An attacker
who tampers the feed transport, swaps the artifact, or even re-signs the
installer with a valid Authenticode certificate still cannot forge step 5. The
SHA-256 check is a cheap fail-fast that does **not** weaken this: rewriting the
feed's `sha256` to match a malicious payload does not let the attacker forge the
Ed25519 signature over a descriptor for that payload (proven by
`UpdateFeedVerifierTests.SignatureBeatsRewrittenSha256`).

## Regenerating the sample

The sample above was produced by the release generator
([`OpenBurnBar.Updater.Generator`](../OpenBurnBar.Updater.Generator)) over
`sample-artifact.txt` with a throwaway dev Ed25519 seed. The seed is **not**
committed — private keys never live in git. To regenerate with your own dev key:

```bash
openssl rand -hex 32 > /tmp/dev-ed25519-seed.hex
dotnet run --project windows/packaging/updater/OpenBurnBar.Updater.Generator -- \
  --version 1.4.2 --build 1420 --bundle-id com.openburnbar.app \
  --artifact windows/packaging/updater/feed/sample-artifact.txt \
  --download-url https://dl.openburnbar.app/windows/OpenBurnBar-Setup-1.4.2.msix \
  --appcast-url https://dl.openburnbar.app/windows/appcast-windows.xml \
  --ed-seed-file /tmp/dev-ed25519-seed.hex \
  --appcast-out windows/packaging/updater/feed/appcast-windows.xml \
  --json-out windows/packaging/updater/feed/latest-windows.json
```

then copy the printed `pinnedKey=` value into `pinned-update-key.pub`.

## Production (dev-host / CI-deferred)

At release time the generator runs on a **Windows runner** over the real signed
**MSIX**, with the **production** pinned Ed25519 private seed injected from a CI
secret (W0 procurement). The actual MSIX build + Authenticode signing + the live
WinSparkle round-trip need Windows runners and the W0 cert; those are flagged
CI/dev-host-deferred. Everything provable on macOS — feed parse, the pinned
Ed25519 verify, SHA-256, version/downgrade logic, and XML/JSON well-formedness —
is proven here and by `windows/tests/updater`.
