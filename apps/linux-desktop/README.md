# OpenBurnBar Linux desktop shell

Tauri 2 + React 19 + Vite shell for mission-001 `W06LinuxShellUx`.

## Architecture

- `src/main.tsx` — boot (perf `app.start`, reduced motion, onboarding redirect) + React mount.
- `src/state/shellStore.ts` — Zustand shell store (route, daemon health, fixture mode, skin, bridge); `useDaemonStatusCopy()`.
- `src/app/App.tsx` — layout landmarks (skip link → `nav[aria-label="Primary"]` → `main#main`).
- `src/components/` — design-system primitives (SurfaceCard, DataTable, Banner, OfflineNotice, FailureStateList, StatusPill, ProviderGlyphs, Sparkline, MeshBackdrop).
- `src/surfaces/` — one module per route; `SurfaceRouter.tsx` is the route→surface registry.
- `src/styles/tokens.css` (generated from `packages/design-tokens/`) + `src/styles/app.css` (skins + component styles; nav geometry is pinned by the packaged smoke).

UI parity work is planned as parallel task packets in
[`docs/linux-port/ui-parity/`](../../docs/linux-port/ui-parity/README.md) —
read that README before changing surfaces.

## Dev (web preview)

```bash
npm install
npm run dev
```

Browser preview shows honest degraded daemon state (no Tauri bridge).

## Packaged Linux build

Requires the Linux toolchain image (`openburnbar-linux-toolchain:mission-001`) with GTK/WebKit/AppIndicator dev packages.

```bash
docker build -t openburnbar-linux-toolchain:mission-001 ../../tools/linux-toolchain
npm install
npm run tauri:build
```

## Evidence

```bash
node ../../scripts/linux-port/run-shell-smoke.mjs
```

Artifacts land in `docs/linux-port/evidence/mission-001-shell-ux/`.
The smoke writes route/a11y/failure/onboarding/pet/text-expansion/perf artifacts
and runs a packaged `.deb` install/run/uninstall proof inside the Linux
toolchain image.

For the desktop integration proof only:

```bash
node ../../scripts/linux-port/run-shell-desktop-session.mjs
```

That wrapper runs `scripts/linux-port/linux-desktop-session.sh` in Docker using a
documented DBus + Xvfb + Openbox + XFCE status-notifier CI compositor profile.
It installs the generated `.deb`, starts the Tauri app against an AF_UNIX daemon
socket, captures screenshots/accessibility/window artifacts, drives the
AppIndicator menu through DBusMenu `Open`, `Reconnect`, and `Quit`, then removes
the package with `dpkg -r`.
