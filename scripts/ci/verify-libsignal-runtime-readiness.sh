#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

python3 scripts/ci/check_libsignal_runtime_readiness.py --launch-gate
