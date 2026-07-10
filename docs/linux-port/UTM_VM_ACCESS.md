# OpenBurnBar Linux UTM VM Access

## Live VM

| Field | Value |
|---|---|
| UTM name | `OpenBurnBar Linux` |
| UUID | `7923D0DD-6367-45EA-9064-152EECC1AC65` |
| Guest IP (vmnet-shared) | `192.168.64.5` |
| OS | Ubuntu 24.04.4 LTS aarch64 |
| Users | `burnbar`, `ubuntu` (admin) |
| SSH key (host) | `~/.ssh/openburnbar_linux_vm` |
| Guest agent | `utmctl exec "OpenBurnBar Linux" --cmd …` |

## SSH

```bash
ssh -i ~/.ssh/openburnbar_linux_vm burnbar@192.168.64.5
```

Key was installed via guest agent into `~/.ssh/authorized_keys` for `burnbar`, `ubuntu`, and `root`.

## Daemon

```bash
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
- Peer RPC probe binary: `/opt/openburnbar/bin/openburnbar-linux-desktop` (app identity) or `/usr/local/bin/openburnbar-cli` (cli identity)

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

### Branch rebuild notes

```bash
export PATH="/opt/swift-6.1-RELEASE-ubuntu24.04-aarch64/usr/bin:$PATH"
cd ~/BurnBar/OpenBurnBarDaemon
swift build -c release --product OpenBurnBarDaemon -Xlinker --allow-shlib-undefined
# Runtime: /opt/openburnbar/lib/swift must match Swift 6.1 (rsync from toolchain if needed)
```

## Sync loop

```bash
rsync -az -e 'ssh -i ~/.ssh/openburnbar_linux_vm -o StrictHostKeyChecking=no' \
  --exclude node_modules --exclude .git --exclude '**/target' --exclude android --exclude windows \
  /Users/albertonunez/Documents/Developer/BurnBar/ burnbar@192.168.64.5:~/BurnBar/
```
