#!/usr/bin/env bash
set -euo pipefail

echo "== runner =="
uname -a
cat /etc/os-release

echo "== swift =="
swift --version
cat > /tmp/OpenBurnBarLinuxSmoke.swift <<'SWIFT'
print("swift-smoke-ok")
SWIFT
swift /tmp/OpenBurnBarLinuxSmoke.swift

echo "== node-npm =="
node --version
npm --version
node -e 'console.log(JSON.stringify({ nodeSmoke: true, platform: process.platform, arch: process.arch }))'

echo "== rust-cargo =="
rustc --version
cargo --version
tmp_cargo="$(mktemp -d)"
trap 'rm -rf "$tmp_cargo"' EXIT
cargo new --quiet --bin "$tmp_cargo/openburnbar_linux_smoke"
cargo run --quiet --manifest-path "$tmp_cargo/openburnbar_linux_smoke/Cargo.toml"

echo "== sqlite-sqlcipher =="
sqlite3 --version
sqlcipher -version
pkg-config --modversion sqlite3
pkg-config --modversion sqlcipher || echo "sqlcipher.pc unavailable; binary and dpkg package evidence recorded"

echo "== linux-desktop-libs =="
pkg-config --modversion webkit2gtk-4.1
pkg-config --modversion ayatana-appindicator3-0.1
pkg-config --modversion libsecret-1
pkg-config --modversion libpipewire-0.3
pkg-config --modversion dbus-1
dpkg-query -W -f='xdg-desktop-portal=${Version}\n' xdg-desktop-portal
/usr/libexec/xdg-desktop-portal --version
dpkg-query -W -f='xdg-desktop-portal-gtk=${Version}\n' xdg-desktop-portal-gtk
test -x /usr/libexec/xdg-desktop-portal-gtk
if /usr/libexec/xdg-desktop-portal-gtk --version 2>/tmp/xdg-desktop-portal-gtk.version.err; then
  :
else
  echo "xdg-desktop-portal-gtk executable present; --version requires a display in this headless container"
  cat /tmp/xdg-desktop-portal-gtk.version.err
fi
pkg-config --modversion libei-1.0
pkg-config --modversion atspi-2
pkg-config --modversion x11
pkg-config --modversion xrandr
pkg-config --modversion xcb
pkg-config --modversion xkbcommon
dpkg-query -W -f='libkf5wallet-dev=${Version}\n' libkf5wallet-dev
test -f /usr/lib/aarch64-linux-gnu/cmake/KF5Wallet/KF5WalletConfig.cmake

echo "== package-signing-tools =="
dpkg-deb --version | head -n 1
dpkg-buildpackage --version | head -n 1
fakeroot --version
rpmbuild --version
gpg --version | head -n 1
patchelf --version
file --version | head -n 1

echo "== package-version-manifest =="
echo "swift=official-swift-docker ${SWIFT_VERSION:-unknown} ${SWIFT_PLATFORM:-unknown} ${SWIFT_SIGNING_KEY:-unknown-signing-key}"
dpkg-query -W -f='${binary:Package}=${Version}\n' \
  nodejs \
  npm \
  rustc \
  cargo \
  sqlite3 \
  sqlcipher \
  libsqlcipher-dev \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  libsecret-1-dev \
  libkf5wallet-dev \
  dbus \
  dbus-x11 \
  xdg-desktop-portal \
  xdg-desktop-portal-gtk \
  pipewire \
  libpipewire-0.3-dev \
  libei-dev \
  libatspi2.0-dev \
  libx11-dev \
  libxrandr-dev \
  libxcb1-dev \
  libxkbcommon-dev \
  dpkg-dev \
  fakeroot \
  rpm \
  gnupg \
  patchelf \
  file

echo "openburnbar-linux-toolchain-smoke-ok"
