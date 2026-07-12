# MSIX visual assets

`Package.appxmanifest` and `OpenBurnBar.Packaging.wapproj` reference the tile / logo
PNGs in this folder. The committed scale-100 assets are generated from
`windows/app/OpenBurnBar.App/Assets/AppLogo.png` so the Windows tiles match the app icon
used by the WinUI shell.

Windows release builds may add the full scaled set (each also emits
`.scale-100/125/150/200/400` and, for the 44×44,
`.targetsize-*` + `.altform-unplated` variants) so MakePri packs every DPI:

| File | Size (scale-100) | Manifest reference |
|------|------------------|--------------------|
| `Square44x44Logo.png`  | 44×44   | `Application/uap:VisualElements@Square44x44Logo`, protocol + file-assoc logos |
| `Square150x150Logo.png`| 150×150 | `Application/uap:VisualElements@Square150x150Logo` |
| `SmallTile.png`        | 71×71   | `uap:DefaultTile@Square71x71Logo` |
| `LargeTile.png`        | 310×310 | `uap:DefaultTile@Square310x310Logo` |
| `Wide310x150Logo.png`  | 310×150 | `uap:DefaultTile@Wide310x150Logo` |
| `StoreLogo.png`        | 50×50   | `Properties/Logo` (Store listing + Apps & Features) |
| `SplashScreen.png`     | 620×300 | optional; desktop full-trust apps skip the splash |

The cross-platform packaging verifier fails closed if any committed scale-100 PNG is
missing or has the wrong dimensions. The exact generation + signing steps live in
[`windows/app/DEV_HOST_RUNBOOK.md`](../../../app/DEV_HOST_RUNBOOK.md).
