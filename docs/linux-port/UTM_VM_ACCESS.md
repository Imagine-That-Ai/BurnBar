# OpenBurnBar Linux UTM VM Access

## Live VM

| Field | Value |
|---|---|
| UTM name | `OpenBurnBar Linux` |
| UUID | `7923D0DD-6367-45EA-9064-152EECC1AC65` |
| Backend | QEMU (HVF), package on `/Volumes/Samsung NVME/OpenBurnBar-UTM/` |
| Network | Emulated VLAN + host port forward (vmnet-shared host→guest is broken on this Mac) |
| SSH (host) | `127.0.0.1:2222` → guest `:22` |
| Guest IP (emulated) | `10.0.2.15` |
| OS | Ubuntu 24.04 LTS aarch64 |
| Users | `burnbar`, `ubuntu` (admin) |
| SSH key (host) | `~/.ssh/openburnbar_linux_vm` |
| Guest agent | `utmctl exec "OpenBurnBar Linux" --cmd …` |
| P-16 Linux root | `/home/burnbar/OpenBurnBar-P16-Coordination` (mode `0700`) |

## SSH

```bash
ssh -i ~/.ssh/openburnbar_linux_vm -p 2222 burnbar@127.0.0.1
```

Optional `~/.ssh/config` Host entry:

```sshconfig
Host openburnbar-linux
  HostName 127.0.0.1
  Port 2222
  User burnbar
  IdentityFile ~/.ssh/openburnbar_linux_vm
  IdentitiesOnly yes
```

Key is in `~/.ssh/authorized_keys` for `burnbar` and `ubuntu`.
## Daemon

```bash
# The packaged daemon is a per-user systemd service. Do not query or enable
# `openburnbar-daemon.service` in the system scope; that is a different unit.
systemctl --user status openburnbar-daemon.service
systemctl --user start openburnbar-daemon.service

# Preferred launch (sets LD_LIBRARY_PATH + XDG paths + index DB)
/usr/libexec/openburnbar-daemon-launch
# Or known-good wrapper shipped with packages
/usr/local/bin/openburnbar-daemon-run
```

- Socket: `$XDG_RUNTIME_DIR/openburnbar/daemon.sock`
- Token: `$XDG_DATA_HOME/openburnbar/daemon-socket-auth-token` (mode 0600)
- Swift libs in the current mutable VM baseline: `/opt/openburnbar/lib/swift`
  (new release packages use `/usr/lib/openburnbar/swift` and
  `/usr/lib/openburnbar/native`)
- Peer RPC probe binary: `/usr/bin/openburnbar-linux-desktop` (app identity) or
  `/usr/bin/openburnbar-cli` (CLI identity). Both are root-owned installed peers;
  the CLI now reads the canonical token file without an environment override.

The daemon health check is authenticated AF_UNIX RPC, not an HTTP service on
`127.0.0.1:8080`. Use the packaged CLI (or the desktop shell's
`--daemon-health` probe) rather than `curl`:

```bash
openburnbar-cli health
/usr/bin/openburnbar-linux-desktop --daemon-health
```

## Repo on guest

`/home/burnbar/BurnBar` (rsync from host; excludes node_modules/git/build artifacts).

## Verified on guest (2026-07-09)

- `npm test --prefix apps/linux-desktop` → **375 pass**
- `npm run build` after `packages/design-tokens` build → **pass**
- **Branch daemon** installed at `/usr/local/bin/openburnbar-daemon` (build `90d0eb3d…`, prebuilt bak kept)
- AF_UNIX `daemon.health` → **ok**, `gatewayEnabled=true` on `:8317`
- `daemon.config.get` via app peer → **ok**
- `daemon.computer_use.approval.pending` → empty requests (params optional)
- Gateway `/v1/models/catalog` → **`catalog=true` platform=linux n=67** (prebuilt was 404)
- Secret Service: `secret-tool` store/lookup → **ok**
- Matrix harness: Linux + display + dbus + secret-tool green; KWallet N/A on GNOME
- Desktop process running; tray + main window present in X tree
- Branch E2E evidence: `docs/linux-port/evidence/mission-002-reanchor/vm-e2e/branch-daemon/`

## Live host rebuild (2026-08-02)

- Canonical UTM guest restored on Tikka’s Mac mini with package storage on the
  external Samsung NVME.
- SSH is reachable at `127.0.0.1:2222` (Emulated VLAN hostfwd). Direct
  `192.168.64.5` access fails with `No route to host` on this host’s vmnet
  path; do not treat that IP as the operator access path anymore.
- `utmctl list` shows `7923D0DD-6367-45EA-9064-152EECC1AC65 started OpenBurnBar Linux`.
- Guest agent works (`utmctl exec "OpenBurnBar Linux" --cmd whoami` → `root`).
- P-16 host preflight (`preflight-p16-live-certification.mjs`) passes with
  zero blockers (UTM + vars + Mac root + physical iPad + Mac runner).
- Coordination roots: macOS
  `/Users/dewclaw/OpenBurnBar-P16-Coordination` (`0700`); Linux
  `/home/burnbar/OpenBurnBar-P16-Coordination` (`0700`); SSH round-trip
  markers verified.

## Prior live candidate check (2026-07-19)

- Historical notes below used vmnet-shared `192.168.64.5`. Prefer
  `127.0.0.1:2222` on the current Mac mini host.
- Current daemon `c94e7b6113` was previously alive through the package launcher with
  Swift 6.1 runtime libraries and reported authenticated health through the
  installed desktop peer (`ok=true`, protocol `1`).
- The rebuilt installed CLI resolved the same XDG token file: bare
  `openburnbar-cli health` returned `ok=true` without exported token state.
- The exact-head arm64 DEB (`ee9aabeffc6698e1cb95daf07b2c59ce47de1b55899592e3b92a45dda6586110`)
  was installed and its migration hook preserved both deliberately stale CLI
  backups. That was a live runtime receipt, not strict release certification:
  the installed manifest is unsigned and the seven-environment/product receipt
  matrix is still open.
- Captured transcript and hashes:
  `evidence/mission-002-reanchor/vm-e2e/current-c94e7b6113/health.json`.

### Branch rebuild notes

```bash
export PATH="/opt/swift-6.1-RELEASE-ubuntu24.04-aarch64/usr/bin:$PATH"
cd ~/BurnBar/OpenBurnBarDaemon
swift build -c release --product OpenBurnBarDaemon -Xlinker --allow-shlib-undefined
# Runtime: /opt/openburnbar/lib/swift must match Swift 6.1 (rsync from toolchain if needed)
```

## Sync loop

```bash
rsync -az -e 'ssh -i ~/.ssh/openburnbar_linux_vm -p 2222 -o StrictHostKeyChecking=no' \
  --exclude node_modules --exclude .git --exclude '**/target' --exclude android --exclude windows \
  /Users/dewclaw/BurnBar/ burnbar@127.0.0.1:~/BurnBar/
```
