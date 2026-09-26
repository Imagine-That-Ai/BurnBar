# Apple Root Certificate Authorities — vendored

These three Apple-published root certificates are loaded by `verifier.ts`
to validate the `x5c` chain of every App Store Server JWS we accept.

## Provenance and SHA-256 fingerprints

| File | Source URL (Apple PKI) | SHA-256 fingerprint |
|------|------------------------|----------------------|
| `AppleRootCA-G3.cer` | <https://www.apple.com/certificateauthority/AppleRootCA-G3.cer> | `63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179` |
| `AppleRootCA-G2.cer` | <https://www.apple.com/certificateauthority/AppleRootCA-G2.cer> | `c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050` |
| `AppleIncRootCertificate.cer` | <https://www.apple.com/appleca/AppleIncRootCertificate.cer> | `b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024` |

The fingerprints listed above are the authoritative pin: `verifier.ts`
recomputes SHA-256 of each `.cer` at cold start and **fails fast** if any
file does not match. That guarantees a vendoring drift, supply-chain
tamper, or accidental file replacement is detected before any JWS is
trusted.

## Why three roots

App Store JWS signing is anchored at **AppleRootCA-G3** today (ECDSA P-384,
the canonical SOTA root for App Store Server API and Server Notifications V2).
The G2 and AppleInc roots are bundled for chain-coverage robustness:

- **G3** — current chain for all v2 signed payloads (transactions, renewal
  info, server notifications, app transactions). Required.
- **G2** — older chain occasionally observed for legacy receipts and
  intermediate cross-signing.
- **AppleInc Root** — the original Apple-issued root retained for the
  small number of historical signing leaves that still chain to it.

The Apple library walks the chain to the first matching root, so adding
extra trusted roots is safe; missing the right root is a hard failure.

## Refreshing

If Apple rotates a root, **never blindly replace** these files. Procedure:

1. Download the new `.cer` from the Apple PKI page above.
2. Compute SHA-256 (`shasum -a 256 file.cer`).
3. Cross-check the fingerprint against
   <https://www.apple.com/certificateauthority/> (Apple lists all current
   fingerprints in the page body).
4. Replace the file **and** update the fingerprint in this README **and**
   the pin in `functions/src/appstore/verifier.ts`.
5. Run `npm --prefix functions run build && npm --prefix functions run lint`.
6. Run the appstore tests against fresh fixtures.

## Why we vendor instead of fetching at runtime

Apple's PKI URLs are highly available, but a Cloud Function that fetches
its own trust anchors at cold start is exactly the boundary an attacker
who controls DNS or TLS to `apple.com` would attack. Vendored, pinned,
and SHA-256-verified bytes are the SOTA choice.
