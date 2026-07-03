# Mission 001 Ops Setup Evidence

This evidence pack establishes the implementation boundary and Linux toolchain
runner for the OpenBurnBar Linux desktop port.

## Boundary

- Main checkout: `/Users/albertonunez/Documents/Developer/BurnBar`
- Main checkout branch at boundary capture: `docs/windows-port-master-plan`
- Main checkout HEAD at boundary capture: `86435e53249c89ce4e3509a769afcfd0cbf2d77d`
- Protected path inventory: `protected-paths-main.txt`
- Full main checkout status snapshot: `main-checkout-status.v2.txt`
- Isolated implementation worktree: `/private/tmp/openburnbar-linux-mission-001`
- Isolated branch: `zenith-mission-001-linux-setup`
- Isolated branch base/upstream: `origin/main`
- Isolated branch HEAD at creation: `5f0650bbde30320a5354662f2a438c2c52c2b292`

The main checkout was dirty before setup work. Those paths are treated as
user-owned and protected. Mission files were created only in the isolated
worktree after an accidental `tools/linux-toolchain/` add in the main checkout
was removed before any staging or commit.

## Runner Selection

Docker was selected as the Linux runner because Docker was installed locally,
while `colima`, `limactl`, `podman`, `nerdctl`, `multipass`, `vagrant`, and
`act` were not present. Docker Desktop was initially not running; it was started
with `docker desktop start` and verified with `docker desktop status`.

- Docker status: `docker-desktop-status.txt`
- Docker versions: `docker-version.txt`
- Docker runner details: `docker-info.txt`

Runner summary:

- Docker Desktop status: running
- Docker Desktop version: `4.64.0 (221278)`
- Docker Engine: `29.2.1`
- Linux runner OS/arch: `linux/arm64`
- Linux kernel: `6.12.72-linuxkit`

## Toolchain Image

Image tag:

```text
openburnbar-linux-toolchain:mission-001
```

Base image:

```text
swift:6.2-noble@sha256:dd349c6dfc3cd3040910a84ab3e5bd5d08efdd547e5fb9f77b765abed16fe5ff
```

Built image id:

```text
sha256:cd30d3f99b8980fa8ab15a04773fe0e54e53bc7fcca7c756d137c4a9eae0dc0d
```

Install commands live in `tools/linux-toolchain/Dockerfile`. Image metadata and
build command history are recorded in:

- `docker-image-inspect.json`
- `docker-image-history.txt`

Installed tool/dependency families:

- Swift 6.2 on Ubuntu Noble
- Node.js and npm
- Rust and Cargo
- SQLite and SQLCipher development packages
- WebKitGTK 4.1 and GTK 3 development packages
- Ayatana AppIndicator
- libsecret and KWallet development packages
- DBus and XDG desktop portal packages
- PipeWire, libei, AT-SPI2, X11, XRandR, XCB, xkbcommon
- Debian/RPM/package/signing tooling: `dpkg-dev`, `fakeroot`, `rpm`, `gnupg`,
  `patchelf`, `file`

## Smoke Evidence

The real Linux smoke command was:

```bash
docker run --rm openburnbar-linux-toolchain:mission-001
```

The full successful output is `smoke-output.txt`. It records:

- `Swift version 6.2.4 (swift-6.2.4-RELEASE)`
- `swift-smoke-ok`
- `node v18.19.1`, `npm 9.2.0`, and a Linux/arm64 Node execution
- `rustc 1.75.0`, `cargo 1.75.0`, and a compiled Cargo hello-world run
- `sqlite3 3.45.1`
- `SQLCipher 4.5.6 community`
- WebKitGTK/AppIndicator/libsecret/PipeWire/DBus/pkg-config versions
- XDG portal package versions
- libei, AT-SPI2, X11, XRandR, XCB, xkbcommon versions
- KWallet development package presence and CMake config presence
- dpkg, fakeroot, rpm, gpg, patchelf, and file versions
- `openburnbar-linux-toolchain-smoke-ok`

`xdg-desktop-portal-gtk --version` tries to open a display in this headless
container. The smoke therefore verifies the package and executable presence,
records the display warning, and does not treat that expected headless behavior
as a setup failure.

## Command Transcript

Boundary and isolation commands:

```bash
git status --porcelain=v2 --branch -uall
git worktree list --porcelain
docker version
docker info
docker desktop status
command -v colima
command -v limactl
command -v podman
command -v nerdctl
command -v multipass
command -v vagrant
command -v act
git worktree add -b zenith/mission-001-linux-setup /private/tmp/openburnbar-linux-mission-001 origin/main
git worktree add -b zenith-mission-001-linux-setup /private/tmp/openburnbar-linux-mission-001 origin/main
```

The slash-containing branch attempt failed because Git could not create
`refs/heads/zenith/...` in this checkout. The first flat-branch attempt failed
under sandboxed `.git` write permissions. The escalated flat-branch command
succeeded.

Runner and setup commands:

```bash
docker desktop start
docker pull swift:6.2-noble
docker build --progress=plain -t openburnbar-linux-toolchain:mission-001 tools/linux-toolchain
docker run --rm openburnbar-linux-toolchain:mission-001
docker image inspect openburnbar-linux-toolchain:mission-001
docker history --no-trunc openburnbar-linux-toolchain:mission-001
```

No broad clean/reset/stage commands were used. Specifically, this setup did not
run `git reset`, `git clean`, `git checkout --`, `git restore .`, `git add .`,
or `git add -A`.

## Discovered Issues

- The local OpenBurnBar castle worktree isolation helper failed against this
  linked worktree because `/private/tmp/openburnbar-linux-mission-001/.git` is a
  file, not a directory. Git worktree isolation remains verified by branch,
  upstream, and status artifacts.
- SQLCipher runtime was present before `libsqlcipher-dev`, but the first smoke
  found that development package evidence was incomplete. The Dockerfile now
  installs `libsqlcipher-dev`.
- `xdg-desktop-portal-gtk --version` requires a display in the headless
  container; the smoke records executable/package presence plus the warning.

