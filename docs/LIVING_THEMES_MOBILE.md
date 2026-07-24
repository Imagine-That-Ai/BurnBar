# Living Themes on OpenBurnBar Mobile

OpenBurnBar’s iOS and Android apps expose the same 42-theme catalog through
Settings → Living Themes and through the public handoff URL:

```text
burnbar://living-theme?theme=fluid-aurora&quality=eco
```

`theme` must be a catalog id. `quality` accepts `eco`, `atelier`, or `cinema`;
unknown quality values safely fall back to Eco.

## Platform behavior

- Android installs a true system live wallpaper. The app renders committed,
  offline GLES3 shader assets from
  `android/app/src/main/assets/living-themes/kernels`. Rendering defaults to
  20 fps and stops completely whenever the wallpaper is not visible.
- iPhone renders the selected theme natively and exports a paired three-second
  Live Photo. The user completes Apple’s required final step in Wallpaper
  Settings. Catalog thumbnails are static; only the selected hero preview
  animates, and full-resolution frames are generated only after Save.

The existing OpenBurnBar usage-swarm wallpaper remains a separate option on
both platforms.

## Catalog maintenance

The committed Android shader files are generated snapshots of the Imagine That
kernel catalog. Any catalog change must keep these in lockstep:

- `OpenBurnBarMobile/Models/MobileBackdropKernel.swift`
- `android/app/src/main/java/com/openburnbar/ui/settings/MobileBackdropKernel.kt`
- `android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LiveTheme.kt`
- `android/app/src/main/assets/living-themes/kernels`

Validate Android asset coverage with:

```bash
node scripts/verify-living-theme-assets.mjs
```

Platform catalog and deep-link parity are also enforced by the iOS and Android
unit tests.
