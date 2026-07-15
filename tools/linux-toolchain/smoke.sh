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
tmp_sqlcipher_db="$(mktemp /tmp/openburnbar-sqlcipher-fts5.XXXXXX.db)"
tmp_sqlcipher_wrong_out="$(mktemp /tmp/openburnbar-sqlcipher-wrong.XXXXXX.out)"
tmp_sqlcipher_wrong_err="$(mktemp /tmp/openburnbar-sqlcipher-wrong.XXXXXX.err)"
tmp_plain_sqlite_out="$(mktemp /tmp/openburnbar-plain-sqlite.XXXXXX.out)"
tmp_plain_sqlite_err="$(mktemp /tmp/openburnbar-plain-sqlite.XXXXXX.err)"
rm -f "$tmp_sqlcipher_db"
trap 'rm -rf "$tmp_cargo" "$tmp_sqlcipher_db" "$tmp_sqlcipher_wrong_out" "$tmp_sqlcipher_wrong_err" "$tmp_plain_sqlite_out" "$tmp_plain_sqlite_err"' EXIT
cargo new --quiet --bin "$tmp_cargo/openburnbar_linux_smoke"
cargo run --quiet --manifest-path "$tmp_cargo/openburnbar_linux_smoke/Cargo.toml"

echo "== sqlite-sqlcipher =="
sqlite3 --version
which sqlcipher
sqlcipher -version
pkg-config --modversion sqlite3
pkg-config --modversion sqlcipher
pkg-config --cflags --libs sqlcipher
ldd "$(command -v sqlcipher)"
cat /usr/local/share/openburnbar/sqlcipher-build.txt
cat /usr/local/share/openburnbar/sqlcipher-source.sha256

echo "== sqlcipher-codec-fts5 =="
sqlcipher_version="$(sqlcipher -batch :memory: 'PRAGMA cipher_version;')"
if [[ -z "$sqlcipher_version" ]]; then
  echo "SQLCipher codec is unavailable: PRAGMA cipher_version returned no row" >&2
  exit 1
fi
echo "cipher_version=${sqlcipher_version}"
compile_options="$(sqlcipher -batch :memory: 'PRAGMA compile_options;')"
printf '%s\n' "$compile_options"
if ! grep -qx 'HAS_CODEC' <<<"$compile_options"; then
  echo "SQLCipher compile options do not include HAS_CODEC" >&2
  exit 1
fi
if ! grep -qx 'ENABLE_FTS5' <<<"$compile_options"; then
  echo "SQLCipher compile options do not include ENABLE_FTS5" >&2
  exit 1
fi
sqlcipher -batch "$tmp_sqlcipher_db" >/dev/null <<'SQL'
PRAGMA key = 'openburnbar-linux-toolchain-smoke';
CREATE TABLE docs(id INTEGER PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL);
CREATE VIRTUAL TABLE docs_fts USING fts5(title, body, content='docs', content_rowid='id');
INSERT INTO docs(id, title, body) VALUES
  (1, 'Toolchain', 'SQLCipher encrypted searchable schema proof'),
  (2, 'Plain SQLite', 'This row proves ordinary sqlite is not the selected storage engine');
INSERT INTO docs_fts(rowid, title, body) SELECT id, title, body FROM docs;
SQL
fts5_result="$(sqlcipher -batch "$tmp_sqlcipher_db" "PRAGMA key = 'openburnbar-linux-toolchain-smoke'; SELECT title || '|' || body FROM docs_fts WHERE docs_fts MATCH 'encrypted AND searchable';" | tail -n 1)"
echo "fts5_query_result=${fts5_result}"
if [[ "$fts5_result" != "Toolchain|SQLCipher encrypted searchable schema proof" ]]; then
  echo "Unexpected encrypted FTS5 query result: ${fts5_result}" >&2
  exit 1
fi
encrypted_header_hex="$(dd if="$tmp_sqlcipher_db" bs=16 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
echo "encrypted_header_hex=${encrypted_header_hex}"
if [[ "$encrypted_header_hex" == "53514c69746520666f726d6174203300" ]]; then
  echo "SQLCipher smoke database has a plaintext SQLite header" >&2
  exit 1
fi
if sqlite3 "$tmp_sqlcipher_db" 'SELECT count(*) FROM sqlite_master;' >"$tmp_plain_sqlite_out" 2>"$tmp_plain_sqlite_err"; then
  echo "Plain sqlite3 unexpectedly opened the SQLCipher smoke database" >&2
  cat "$tmp_plain_sqlite_out" >&2
  exit 1
fi
echo "plain_sqlite_rejected=$(tr '\n' ' ' < "$tmp_plain_sqlite_err")"
if sqlcipher -batch "$tmp_sqlcipher_db" "PRAGMA key = 'wrong-openburnbar-key'; SELECT count(*) FROM sqlite_master;" >"$tmp_sqlcipher_wrong_out" 2>"$tmp_sqlcipher_wrong_err"; then
  echo "SQLCipher unexpectedly opened the smoke database with the wrong key" >&2
  cat "$tmp_sqlcipher_wrong_out" >&2
  exit 1
fi
echo "wrong_key_rejected=$(tr '\n' ' ' < "$tmp_sqlcipher_wrong_err")"

echo "== linux-desktop-libs =="
pkg-config --modversion webkit2gtk-4.1
pkg-config --modversion ayatana-appindicator3-0.1
pkg-config --modversion libsecret-1
dpkg-query -W -f='libpam0g-dev=${Version}\n' libpam0g-dev
test -f "$(cc -print-file-name=libpam.so)"
pkg-config --modversion libpipewire-0.3
pkg-config --modversion gstreamer-1.0
pkg-config --modversion gstreamer-app-1.0
pkg-config --modversion gstreamer-video-1.0
gst-inspect-1.0 --version
gst-inspect-1.0 vp9dec >/dev/null
gst-inspect-1.0 autovideosink >/dev/null
gst-inspect-1.0 pipewiresrc >/dev/null
gst-inspect-1.0 pipewiresink >/dev/null
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
command -v Xvfb
command -v openbox
command -v xfce4-panel
command -v xdotool
command -v scrot
command -v gdbus
command -v orca
orca --version
python3 -c 'import pyatspi; print("python3-pyatspi=import-ok")'
dpkg-query -W -f='xfce4-sntray-plugin=${Version}\n' xfce4-sntray-plugin
dpkg-query -W -f='ayatana-indicator-application=${Version}\n' ayatana-indicator-application
dpkg-query -W -f='libkf5wallet-dev=${Version}\n' libkf5wallet-dev
test -f /usr/lib/aarch64-linux-gnu/cmake/KF5Wallet/KF5WalletConfig.cmake

echo "== package-signing-tools =="
dpkg-deb --version | sed -n '1p'
dpkg-buildpackage --version | sed -n '1p'
fakeroot --version
rpmbuild --version
mksquashfs -version | sed -n '1p'
gpg --version | sed -n '1p'
patchelf --version
file --version | sed -n '1p'

echo "== package-version-manifest =="
echo "swift=official-swift-docker ${SWIFT_VERSION:-unknown} ${SWIFT_PLATFORM:-unknown} ${SWIFT_SIGNING_KEY:-unknown-signing-key}"
echo "rustc=$(rustc --version)"
echo "cargo=$(cargo --version)"
dpkg-query -W -f='${binary:Package}=${Version}\n' \
  xvfb \
  openbox \
  xfce4-panel \
  xfce4-sntray-plugin \
  ayatana-indicator-application \
  xdotool \
  x11-utils \
  scrot \
  at-spi2-core \
  orca \
  python3-pyatspi \
  curl \
  tcl \
  sqlite3 \
  libreadline-dev \
  libwebkit2gtk-4.1-dev \
  libayatana-appindicator3-dev \
  libsecret-1-dev \
  libpam0g-dev \
  libkf5wallet-dev \
  dbus \
  dbus-x11 \
  xdg-desktop-portal \
  xdg-desktop-portal-gtk \
  pipewire \
  libpipewire-0.3-dev \
  gstreamer1.0-plugins-base \
  gstreamer1.0-plugins-good \
  gstreamer1.0-pipewire \
  gstreamer1.0-tools \
  libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev \
  libei-dev \
  libatspi2.0-dev \
  libx11-dev \
  libxrandr-dev \
  libxcb1-dev \
  libxkbcommon-dev \
  dpkg-dev \
  fakeroot \
  rpm \
  squashfs-tools \
  gnupg \
  patchelf \
  file \
  zlib1g-dev
printf 'node-runtime=%s\nnpm-runtime=%s\n' "$(node --version)" "$(npm --version)"

echo "openburnbar-linux-toolchain-smoke-ok"
