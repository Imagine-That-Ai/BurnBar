# Windows MSIX channels

OpenBurnBar produces two deliberately separate MSIX channels from the same
published binaries:

- **Direct download:** `Package.appxmanifest` supplies the stable sideload
  identity. Azure Artifact Signing signs and timestamps these packages, and the
  OpenBurnBar Ed25519 update feed controls updates.
- **Microsoft Store:** `store-identity.json` records the exact Partner Center
  product identity. These packages are emitted under `artifacts/store/`, remain
  unsigned, and are signed by Microsoft after submission. The packager removes
  the direct-download appcast and Ed25519 pin, then writes
  `Resources/Updates/distribution-channel.json`. The app uses that signed marker
  to delegate update checks and automatic updates to Microsoft Store.

The Store identity values are not secrets. They are case-sensitive release
configuration copied from Partner Center's **Product identity** page. The
package-level display name is also stamped from the reserved product name
(`BurnBar`). Any Partner Center identity or name change must update the JSON,
the distribution tests, and the private-flight evidence together.

Never sign a Store-identity package with the direct-download certificate. The
certificate subject would not match `Package/Identity/Publisher`, and combining
the two channels would also make their update ownership ambiguous.

`Test-MsixPackageIdentity.ps1` unpacks every candidate and fails closed unless
the direct package contains the appcast/key with no Store marker, while the
Store package contains the exact Partner Center product marker with no direct
update metadata.
