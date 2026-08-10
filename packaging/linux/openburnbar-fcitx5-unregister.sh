#!/usr/bin/env bash
# Post-remove cleanup for the OpenBurnBar Fcitx5 addon registration.
#
# Removes only symlinks that point into the (now removed) package-private
# prefix, restoring the host's prior input-method configuration. A user's own
# engine selection is never touched: once the addon disappears from Fcitx5's
# search path, Fcitx5 falls back to its previously configured engines.
set -euo pipefail

unlink_ours() {
  local destination="$1"
  if [[ -L "$destination" ]]; then
    local target
    target="$(readlink "$destination" || true)"
    case "$target" in
      /usr/lib/openburnbar/fcitx5/*|/usr/share/openburnbar/text-expansion/fcitx5/*)
        rm -f "$destination" || true
        ;;
    esac
  fi
}

if command -v gcc >/dev/null 2>&1; then
  triplet="$(gcc -dumpmachine 2>/dev/null || true)"
  [[ -n "$triplet" ]] && unlink_ours "/usr/lib/${triplet}/fcitx5/openburnbar-fcitx5.so"
fi
unlink_ours /usr/lib/fcitx5/openburnbar-fcitx5.so
unlink_ours /usr/share/fcitx5/addon/openburnbar-fcitx5.conf
unlink_ours /usr/share/fcitx5/inputmethod/openburnbar.conf
exit 0
