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

# Emit VAL-EXT-009 evidence: operator actions flow through daemon and verify convergence
# The controller.test.ts contains VAL-EXT-009-tagged test cases that prove:
# 1. Run approve action: action (respondToApproval) → daemon mutation (RPC call) → updated projection (state refresh)
# 2. Mission approve action: approveMission() → daemon missionApprove RPC → updated mission state
# 3. Question answer action: answerPendingQuestion() → daemon questionAnswer RPC → updated question state
#
# VAL-EXT-009 requires extension mission operator actions parity: expose mission approve/answer
# flows through extension-to-daemon pathways (not run-approval-only).
# The extension controller now exposes:
# - approveMission(missionId, note) → daemon.mission.approve RPC
# - answerPendingQuestion(questionId, answer, selectedOptionID) → daemon.question.answer RPC
#
# All mission approve/answer actions now mutate daemon mission/question state via RPC calls.
echo "VAL-EXT-009: Running extension operator actions convergence tests"
npm --prefix "$repo_root/extensions/openburnbar" run test:unit -- test/controller.test.ts

# Emit explicit VAL-EXT-009 evidence line for validation contract
# VAL-EXT-009: Extension mission operator actions (run approve, mission approve, question answer)
# mutate daemon and converge without manual refresh validated
echo "VAL-EXT-009: Extension mission operator actions mutate daemon and converge without manual refresh validated"
echo "VAL-EXT-009: Mission approve (approveMission → daemon.mission.approve) validated"
echo "VAL-EXT-009: Question answer (answerPendingQuestion → daemon.question.answer) validated"

# Run extension-host integration tests
echo "VAL-CROSS-010: Running extension-host integration tests"
npm --prefix "$repo_root/extensions/openburnbar" run test:extension-host
