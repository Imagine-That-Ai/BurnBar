#!/usr/bin/env bash
# Fail closed if security-sensitive paths lose explicit CODEOWNERS coverage.
set -euo pipefail
cd "$(dirname "$0")/../.."

python3 <<'PY'
from __future__ import annotations

import fnmatch
import sys
from pathlib import Path

CODEOWNERS = Path(".github/CODEOWNERS")
SECURITY_OWNERS = {"@Ajnunezg"}

REQUIRED_RULES = [
    ".github/CODEOWNERS",
    ".github/workflows/",
    "functions/src/security/",
    "functions/src/auth.ts",
    "functions/src/appCheckAttestation.ts",
    "functions/src/ssrfGuard.ts",
    "functions/src/logging.ts",
    "functions/src/resilienceHelpers.ts",
    "functions/src/providers/httpClient.ts",
    "functions/src/computerUseRemoteConfig.ts",
    "functions/src/callables/dataExport.ts",
    "functions/src/callables/dataDeletion.ts",
    "functions/src/callables/accountDeletion.ts",
    "functions/src/callables/auditLog.ts",
    "functions/src/callables/stripe*",
    "functions/src/callables/shared/validators.ts",
    "functions/src/callables/publicRateLimit.ts",
    "functions/src/hermesGateway.ts",
    "AgentLens/Services/CloudVaultCrypto.swift",
    "AgentLens/Services/DataStore/DatabaseEncryptionService.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/",
    "OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultCrypto.swift",
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift",
    "scripts/ci/",
    "scripts/ci/prepare-firebase-tools.sh",
    "scripts/ci/write-firebase-hosting-ci-config.mjs",
    "scripts/ci/verify-production-deploy-auth.sh",
    "scripts/ci/verify-production-deploy-auth.test.sh",
    "Vendor/libsignal",
    "Vendor/libsignal/",
    "Vendor/GRDB-SQLCipher/",
    "budgets/",
    "docs/security/",
    "firebase.json",
    ".firebaserc",
    ".github/workflows/deploy-hosting.yml",
    ".github/workflows/deploy-production.yml",
    ".github/workflows/deploy-firestore.yml",
    "website/package.json",
    "apps/console/package.json",
    "functions/package.json",
    "functions/package-lock.json",
    "firestore.rules",
    "firestore.indexes.json",
    "project.yml",
]

EXPECTED_FINAL_RULES = {
    ".github/CODEOWNERS": ".github/CODEOWNERS",
    ".github/workflows/security-pr.yml": ".github/workflows/",
    "functions/src/security/endpointAuthorizationMatrix.ts": "functions/src/security/",
    "functions/src/callables/stripe.ts": "functions/src/callables/stripe*",
    "functions/src/callables/stripeTopUps.ts": "functions/src/callables/stripe*",
    "scripts/ci/verify-ops-readiness.sh": "scripts/ci/",
    "scripts/ci/prepare-firebase-tools.sh": "scripts/ci/prepare-firebase-tools.sh",
    "scripts/ci/write-firebase-hosting-ci-config.mjs": "scripts/ci/write-firebase-hosting-ci-config.mjs",
    "scripts/ci/verify-production-deploy-auth.sh": "scripts/ci/verify-production-deploy-auth.sh",
    "scripts/ci/verify-production-deploy-auth.test.sh": "scripts/ci/verify-production-deploy-auth.test.sh",
    "Vendor/libsignal": "Vendor/libsignal",
    "Vendor/libsignal/swift/Package.swift": "Vendor/libsignal/",
    "Vendor/GRDB-SQLCipher/Package.swift": "Vendor/GRDB-SQLCipher/",
    "firebase.json": "firebase.json",
    ".firebaserc": ".firebaserc",
    ".github/workflows/deploy-hosting.yml": ".github/workflows/deploy-hosting.yml",
    ".github/workflows/deploy-production.yml": ".github/workflows/deploy-production.yml",
    ".github/workflows/deploy-firestore.yml": ".github/workflows/deploy-firestore.yml",
    "website/package.json": "website/package.json",
    "apps/console/package.json": "apps/console/package.json",
    "functions/package.json": "functions/package.json",
    "functions/package-lock.json": "functions/package-lock.json",
    "firestore.rules": "firestore.rules",
    "project.yml": "project.yml",
    "AgentLens/Services/DataStore/DatabaseEncryptionService.swift": "AgentLens/Services/DataStore/DatabaseEncryptionService.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift": "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/",
    "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift": "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/DaemonLocalAuthProofVerifier.swift",
}


class Rule:
    def __init__(self, line_no: int, pattern: str, owners: list[str]) -> None:
        self.line_no = line_no
        self.pattern = pattern
        self.owners = owners


def parse_codeowners(path: Path) -> list[Rule]:
    rules: list[Rule] = []
    if not path.is_file():
        raise SystemExit(f"FAIL: {path} is missing")

    for line_no, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            raise SystemExit(f"FAIL: {path}:{line_no} has a pattern without an owner")
        rules.append(Rule(line_no=line_no, pattern=parts[0], owners=parts[1:]))
    return rules


def rule_matches_path(pattern: str, repo_path: str) -> bool:
    normalized = pattern.lstrip("/")
    if normalized.endswith("/"):
        directory = normalized.rstrip("/")
        return repo_path.startswith(directory + "/")
    if any(ch in normalized for ch in "*?"):
        return fnmatch.fnmatchcase(repo_path, normalized)
    return repo_path == normalized


rules = parse_codeowners(CODEOWNERS)
failures: list[str] = []

for required in REQUIRED_RULES:
    matching_rules = [rule for rule in rules if rule.pattern == required]
    if not matching_rules:
        failures.append(f"missing explicit CODEOWNERS rule for {required}")
        continue
    if not any(SECURITY_OWNERS.issubset(set(rule.owners)) for rule in matching_rules):
        owners = ", ".join(" ".join(rule.owners) for rule in matching_rules)
        failures.append(f"{required} is present but lacks required security/platform owner(s): {owners}")

for path, expected_pattern in EXPECTED_FINAL_RULES.items():
    matching_rules = [rule for rule in rules if rule_matches_path(rule.pattern, path)]
    if not matching_rules:
        failures.append(f"{path} has no CODEOWNERS match")
        continue
    final_rule = matching_rules[-1]
    if final_rule.pattern != expected_pattern:
        failures.append(
            f"{path} final owner rule is {final_rule.pattern!r} on line {final_rule.line_no}; "
            f"expected {expected_pattern!r}. Keep security-sensitive rules last."
        )
    if not SECURITY_OWNERS.issubset(set(final_rule.owners)):
        failures.append(
            f"{path} final rule {final_rule.pattern!r} lacks required security/platform owner(s): "
            + " ".join(final_rule.owners)
        )

if failures:
    print("FAIL: security-sensitive CODEOWNERS coverage drifted:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)

print("PASS: security-sensitive CODEOWNERS rules are explicit and final-match effective.")
PY
