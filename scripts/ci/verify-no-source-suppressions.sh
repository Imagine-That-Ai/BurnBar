#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

pattern='@file:Suppress|@Suppress\(|SuppressLint|swiftlint:disable|//[[:space:]]*detekt:|detekt-baseline|swiftlint-baseline|--baseline|baseline[[:space:]]*=[[:space:]]*file'

if rg -n "$pattern" \
  android \
  AgentLens \
  OpenBurnBarCore \
  OpenBurnBarDaemon \
  OpenBurnBarMobile \
  .github \
  --glob '!**/build/**' \
  --glob '!**/node_modules/**' \
  --glob '!OpenBurnBarMobile/Resources/Mermaid/mermaid.min.js'; then
  printf >&2 '\nSource suppressions or checked-in baselines are not allowed. Fix the code or project-level rule policy instead.\n'
  exit 1
fi
