#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

npm --prefix "$repo_root/extensions/burnbar" run test:replay
