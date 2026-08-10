#!/usr/bin/env bash
# Build the native OpenBurnBar Fcitx5 addon into the package payload staging
# area. Runs inside the Linux toolchain container (cmake + libfcitx5core-dev)
# or any Linux host with the Fcitx5 development headers.
#
# Output layout (consumed by prepare-linux-package-payload.mjs):
#   <out>/openburnbar-fcitx5.so          native addon module
#   <out>/addon/openburnbar-fcitx5.conf  fcitx5 addon registration
#   <out>/inputmethod/openburnbar.conf   fcitx5 input-method registration
#   <out>/build-info.json                compiler/header/digest receipt
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
addon_source="${repo_root}/packaging/linux/fcitx5-addon"
out_dir="${OPENBURNBAR_FCITX5_ADDON_OUT:-${repo_root}/apps/linux-desktop/src-tauri/target/openburnbar-fcitx5-addon}"
build_dir="$(mktemp -d /tmp/openburnbar-fcitx5-build-XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "build-fcitx5-addon: the native Fcitx5 addon builds only on Linux" >&2
  exit 64
fi
for tool in cmake pkg-config c++; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "build-fcitx5-addon: required tool missing: $tool" >&2
    exit 65
  }
done
fcitx5_version="$(pkg-config --modversion Fcitx5Core 2>/dev/null || true)"
if [[ -z "$fcitx5_version" ]]; then
  echo "build-fcitx5-addon: Fcitx5Core development headers are not installed (libfcitx5core-dev)" >&2
  exit 66
fi

cmake -S "$addon_source" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release >"$build_dir/configure.log" 2>&1 || {
  tail -40 "$build_dir/configure.log" >&2
  exit 67
}
cmake --build "$build_dir" --parallel >"$build_dir/build.log" 2>&1 || {
  tail -40 "$build_dir/build.log" >&2
  exit 68
}

test -f "$build_dir/openburnbar-fcitx5.so"
# The module must export the fcitx addon factory entrypoint; a stripped or
# mislinked module would register nothing and silently disable expansion.
if ! nm -D "$build_dir/openburnbar-fcitx5.so" | grep -q "fcitx_addon_factory_instance"; then
  echo "build-fcitx5-addon: built module does not export the fcitx addon factory" >&2
  exit 69
fi
# Safety gate: the addon must never link against evdev/XRecord/XTest input
# capture surfaces — the trigger-only boundary is load-bearing.
if nm -D "$build_dir/openburnbar-fcitx5.so" | grep -Eiq "libevdev|XRecord|XTest"; then
  echo "build-fcitx5-addon: built module references forbidden global-capture symbols" >&2
  exit 70
fi

rm -rf "$out_dir"
mkdir -p "$out_dir/addon" "$out_dir/inputmethod"
# 0755: the daemon's signed-engine trust gate requires the registered engine
# artifact to carry the executable bit (isTrusted(executable: true)).
install -m 0755 "$build_dir/openburnbar-fcitx5.so" "$out_dir/openburnbar-fcitx5.so"
install -m 0644 "$addon_source/openburnbar-fcitx5-addon.conf" "$out_dir/addon/openburnbar-fcitx5.conf"
install -m 0644 "$addon_source/openburnbar-fcitx5-im.conf" "$out_dir/inputmethod/openburnbar.conf"

so_sha256="$(sha256sum "$out_dir/openburnbar-fcitx5.so" | cut -d' ' -f1)"
compiler_version="$(c++ --version | head -1)"
cat >"$out_dir/build-info.json" <<INFO
{
  "schemaVersion": 1,
  "addon": "openburnbar-fcitx5",
  "fcitx5CoreVersion": "${fcitx5_version}",
  "compiler": "${compiler_version}",
  "architecture": "$(uname -m)",
  "soSha256": "${so_sha256}",
  "sourceDir": "packaging/linux/fcitx5-addon"
}
INFO
echo "build-fcitx5-addon: staged ${out_dir}/openburnbar-fcitx5.so (Fcitx5Core ${fcitx5_version}, sha256 ${so_sha256})"
