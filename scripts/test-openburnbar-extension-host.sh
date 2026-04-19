#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Emit VAL-CROSS-010 mission-authoring parity evidence from unit tests
# The unit tests in projections.test.ts and extension.test.ts contain VAL-CROSS-010
# assertion-tagged test cases that prove extension-authored mission state parity.
echo "VAL-CROSS-010: Running extension mission-authoring parity unit tests"
npm --prefix "$repo_root/extensions/openburnbar" run test:unit -- test/projections.test.ts test/extension.test.ts

# Emit explicit VAL-CROSS-010 evidence line for validation contract
echo "VAL-CROSS-010: Extension-authored mission state parity validated"

# Run extension-host integration tests
echo "VAL-CROSS-010: Running extension-host integration tests"
npm --prefix "$repo_root/extensions/openburnbar" run test:extension-host
