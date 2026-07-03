# OpenBurnBar Linux desktop shell

Tauri 2 + Vite shell for mission-001 `W06LinuxShellUx`.

## Dev (web preview)

```bash
npm install
npm run dev
```

Browser preview shows honest degraded daemon state (no Tauri bridge).

## Packaged Linux build

Requires the Linux toolchain image (`openburnbar-linux-toolchain:mission-001`) with GTK/WebKit/AppIndicator dev packages.

```bash
npm install
npm run tauri:build
```

## Evidence

```bash
node ../../scripts/linux-port/run-shell-smoke.mjs
```

Artifacts land in `docs/linux-port/evidence/mission-001-shell-ux/`.