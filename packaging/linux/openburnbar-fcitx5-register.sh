#!/usr/bin/env bash
# Best-effort post-install registration of the OpenBurnBar Fcitx5 addon.
#
# The package installs the addon under the package-private prefix; this hook
# links it into the host's Fcitx5 search paths when (and only when) an Fcitx5
# installation exists. Installation must never fail because Fcitx5 is absent —
# IBus remains the default supported backend. Consent is unaffected: the
# daemon still refuses expansion until external expansion is explicitly
# enabled in OpenBurnBar settings.
set -euo pipefail

addon_so=/usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so
addon_conf=/usr/share/openburnbar/text-expansion/fcitx5/addon/openburnbar-fcitx5.conf
im_conf=/usr/share/openburnbar/text-expansion/fcitx5/inputmethod/openburnbar.conf

[[ -f "$addon_so" && -f "$addon_conf" && -f "$im_conf" ]] || exit 0
command -v fcitx5 >/dev/null 2>&1 || exit 0

link() {
  local source="$1" destination="$2"
  local directory
  directory="$(dirname "$destination")"
  [[ -d "$directory" ]] || return 0
  # Never clobber a foreign file; only manage our own symlink.
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    return 0
  fi
  ln -sf "$source" "$destination" 2>/dev/null || true
}

# Library search path differs per distro family: Debian/Ubuntu use the
# multiarch triplet, Arch and others use /usr/lib/fcitx5.
if command -v gcc >/dev/null 2>&1; then
  triplet="$(gcc -dumpmachine 2>/dev/null || true)"
  [[ -n "$triplet" ]] && link "$addon_so" "/usr/lib/${triplet}/fcitx5/openburnbar-fcitx5.so"
fi
link "$addon_so" /usr/lib/fcitx5/openburnbar-fcitx5.so
link "$addon_conf" /usr/share/fcitx5/addon/openburnbar-fcitx5.conf
link "$im_conf" /usr/share/fcitx5/inputmethod/openburnbar.conf

# A running fcitx5 picks the addon up on its next restart; never restart the
# user's input method from a package hook.
exit 0
