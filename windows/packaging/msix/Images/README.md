# MSIX visual assets

`Package.appxmanifest` and `OpenBurnBar.Packaging.wapproj` reference the tile / logo
PNGs in this folder. The **branded PNGs are produced from the OpenBurnBar app icon on
the Windows dev host** (Visual Studio's *Manifest Designer → Visual Assets* generator,
or `MakePri`/the Windows App SDK asset tool) and are **not committed here** — they are
binary build inputs, generated from the same source glyph as the macOS `AppIcon` so the
Windows tiles match the Mac dock icon.

Generate the full scaled set (each also emits `.scale-100/125/150/200/400` and, for the
44×44, `.targetsize-*` + `.altform-unplated` variants) so MakePri packs every DPI:

| File | Size (scale-100) | Manifest reference |
|------|------------------|--------------------|
| `Square44x44Logo.png`  | 44×44   | `Application/uap:VisualElements@Square44x44Logo`, protocol + file-assoc logos |
| `Square150x150Logo.png`| 150×150 | `Application/uap:VisualElements@Square150x150Logo` |
| `SmallTile.png`        | 71×71   | `uap:DefaultTile@Square71x71Logo` |
| `LargeTile.png`        | 310×310 | `uap:DefaultTile@Square310x310Logo` |
| `Wide310x150Logo.png`  | 310×150 | `uap:DefaultTile@Wide310x150Logo` |
| `StoreLogo.png`        | 50×50   | `Properties/Logo` (Store listing + Apps & Features) |
| `SplashScreen.png`     | 620×300 | optional; desktop full-trust apps skip the splash |

Until the generator runs on the dev host, an unsigned dev pack can substitute the Windows
App SDK template placeholders. The exact generation + signing steps live in
[`windows/app/DEV_HOST_RUNBOOK.md`](../../../app/DEV_HOST_RUNBOOK.md).
