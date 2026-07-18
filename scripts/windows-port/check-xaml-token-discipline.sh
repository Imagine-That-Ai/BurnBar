#!/usr/bin/env bash
# XAML token-discipline gate — the Windows mirror of the Linux shell's
# apps/linux-desktop/src/styles/tokensContract.test.ts: surfaces must consume the
# design-token pipeline (packages/design-tokens → Theme/Tokens.xaml) instead of
# ad-hoc colors and fonts, so the app keeps tracking the macOS/Linux look.
#
# Enforced on windows/app/**/*.xaml OUTSIDE windows/app/OpenBurnBar.App/Theme/
# (Theme/ is where tokens live and may hold raw values):
#   1. No raw hex colors (#RRGGBB / #AARRGGBB), except fully transparent #00000000
#      and the documented allowlist below (bespoke art colors with no token yet —
#      gold shimmer, mercury hairline art, info-blue tool blocks, DCC Pensieve world).
#   2. No hardcoded FontFamily="..." — use {StaticResource AuroraDisplayFont /
#      AuroraBodyFont / AuroraMonoFont / AuroraArcaneFont}. Icon fonts
#      (Segoe MDL2 Assets / Segoe Fluent Icons) are exempt.
#
# To add an exception: add `relative/path.xaml <VALUE>  # reason` to
# scripts/windows-port/xaml-token-allowlist.txt (mirrors docs/LINT_RATIONALE.md).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_root="${repo_root}/windows/app"
theme_root="${app_root}/OpenBurnBar.App/Theme"
allowlist_file="${repo_root}/scripts/windows-port/xaml-token-allowlist.txt"

if [[ ! -f "${allowlist_file}" ]]; then
  echo "xaml-token-discipline: missing allowlist ${allowlist_file}" >&2
  exit 1
fi

failures=0

# Load allowlist into "path|value" pairs (skips comments/blank lines).
allow_pairs=()
while IFS= read -r line; do
  [[ "${line}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  path="$(awk '{print $1}' <<< "${line}")"
  value="$(awk '{print $2}' <<< "${line}")"
  allow_pairs+=("${path}|${value}")
done < "${allowlist_file}"

is_allowed() {
  local rel="$1" value="$2"
  for pair in "${allow_pairs[@]}"; do
    [[ "${pair}" == "${rel}|${value}" ]] && return 0
  done
  return 1
}

while IFS= read -r -d '' file; do
  rel="${file#"${repo_root}"/}"
  # Raw hex colors. #00000000 (fully transparent) is always allowed.
  while IFS= read -r match; do
    hex="$(grep -oE '#[0-9A-Fa-f]{8}|#[0-9A-Fa-f]{6}' <<< "${match}" | head -1)"
    upper="$(tr '[:lower:]' '[:upper:]' <<< "${hex}")"
    [[ "${upper}" == "#00000000" ]] && continue
    if ! is_allowed "${rel}" "${upper}"; then
      lineno="$(grep -nF "${match}" "${file}" | head -1 | cut -d: -f1)"
      echo "xaml-token-discipline: ${rel}:${lineno} raw color ${upper} — use a token brush (or allowlist with a reason)" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -oE '"[^"]*#[0-9A-Fa-f]{6}[^"]*"' "${file}" || true)
  # Hardcoded FontFamily (StaticResource/ThemeResource/x:Bind usages are fine).
  while IFS= read -r match; do
    family="$(sed -E 's/.*FontFamily="([^"]+)".*/\1/' <<< "${match}")"
    case "${family}" in
      *StaticResource* | *ThemeResource* | *Bind*) continue ;;
      *"MDL2 Assets"* | *"Fluent Icons"*) continue ;;  # icon glyph fonts, not text
    esac
    if ! is_allowed "${rel}" "FontFamily"; then
      lineno="$(grep -nF "${match}" "${file}" | head -1 | cut -d: -f1)"
      echo "xaml-token-discipline: ${rel}:${lineno} hardcoded FontFamily=\"${family}\" — use {StaticResource Aurora*Font}" >&2
      failures=$((failures + 1))
    fi
  done < <(grep -oE 'FontFamily="[^"]+"' "${file}" || true)
done < <(find "${app_root}" -name '*.xaml' -not -path "${theme_root}/*" -print0)

# High Contrast must follow the active Windows system palette. Keeping branded
# Aurora/Pensieve colors here makes content unreadable for several contrast themes.
shell_theme="${theme_root}/PensieveShell.xaml"
high_contrast="$(sed -n '/x:Key="HighContrast"/,/<\/ResourceDictionary>/p' "${shell_theme}")"
if [[ -z "${high_contrast}" ]] || ! grep -q 'SystemColorWindowColor' <<< "${high_contrast}"; then
  echo "xaml-token-discipline: ${shell_theme#"${repo_root}"/} must define a system-color HighContrast dictionary" >&2
  failures=$((failures + 1))
fi
if grep -Eq 'Pensieve(ColorMacos|ColorAurora|Glass)|#[0-9A-Fa-f]{6,8}' <<< "${high_contrast}"; then
  echo "xaml-token-discipline: ${shell_theme#"${repo_root}"/} HighContrast dictionary must not force branded colors" >&2
  failures=$((failures + 1))
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "xaml-token-discipline: ${failures} violation(s) — surfaces must consume Theme/ tokens (see scripts/windows-port/xaml-token-allowlist.txt for the documented exceptions)" >&2
  exit 1
fi
echo "xaml-token-discipline: OK (windows/app XAML consumes the token pipeline; $((${#allow_pairs[@]})) documented exception(s))"
