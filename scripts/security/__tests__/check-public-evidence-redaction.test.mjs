import { test } from "node:test";
import assert from "node:assert/strict";
import { scanText } from "../check-public-evidence-redaction.mjs";

test("allows redacted launch evidence placeholders", () => {
  const text = JSON.stringify(
    {
      projectId: "<firebase-project-id>",
      firebaseUid: "<firebase-user-id>",
      deviceSerial: "<android-device-serial>",
      sentryDsn: "<sentry-dsn>",
      serviceAccountEmail: "<service-account-email>",
      secretEnvVarNames: ["<runtime-secret-env-var>"],
    },
    null,
    2,
  );

  assert.deepEqual(scanText("launch-evidence/latest-commercial-launch-gate.json", text), []);
});

test("blocks concrete launch evidence identifiers", () => {
  const text = [
    '{',
    '  "projectId": "prod-project-123",',
    '  "firebaseUid": "abc123def456",',
    '  "deviceSerial": "SERIAL12345",',
    '  "sentryDsn": "https://0123456789abcdef0123456789abcdef@o123456.ingest.sentry.io/9876543",',
    '  "serviceAccountEmail": "release-bot@prod-project-123.iam.gserviceaccount.com",',
    '  "secretEnvVarNames": ["PAYMENT_WEBHOOK_SECRET"]',
    '}',
  ].join("\n");

  const violations = scanText("launch-evidence/current.json", text);
  assert.ok(violations.length >= 6);
  assert.ok(violations.some((violation) => violation.ruleId === "concrete-operational-value"));
  assert.ok(violations.some((violation) => violation.ruleId === "sentry-dsn"));
  assert.ok(violations.some((violation) => violation.ruleId === "service-account-email"));
  assert.ok(violations.some((violation) => violation.ruleId === "secret-env-name-in-evidence"));
});

test("blocks concrete Firebase evidence artifact identifiers", () => {
  const text = [
    "{",
    '  "projectId": "prod-project-123",',
    '  "url": "https://api-us-central1.a.run.app",',
    '  "storageBucket": "prod-project-123.firebasestorage.app",',
    '  "serviceAccountEmail": "release-bot@prod-project-123.iam.gserviceaccount.com"',
    "}",
  ].join("\n");

  const violations = scanText("firebase-security-evidence.json", text);

  assert.ok(violations.length >= 4);
  assert.ok(violations.some((violation) => violation.ruleId === "concrete-operational-value"));
  assert.ok(violations.some((violation) => violation.ruleId === "cloud-run-url"));
  assert.ok(violations.some((violation) => violation.ruleId === "firebase-storage-bucket"));
  assert.ok(violations.some((violation) => violation.ruleId === "service-account-email"));
});

test("blocks physical device ids in operational runbooks", () => {
  const text = [
    "| Device | Identifier |",
    "| --- | --- |",
    "| iPhone | 00008120-001234567890ABCD |",
  ].join("\n");

  const violations = scanText(
    "docs/runbooks/computer-use-device-matrix/phase-12.md",
    text,
  );
  assert.equal(violations.length, 1);
  assert.equal(violations[0].ruleId, "apple-device-udid");
});

test("blocks agent-facing branch protection bypass commands", () => {
  const text = [
    "gh api repos/acme/example/branches/main/protection --field enforce_admins=false",
    "git push origin HEAD:main",
  ].join("\n");

  const violations = scanText("docs/signalification/COMPUTER_USE_AGENT_HANDOFF.md", text);
  assert.deepEqual(
    violations.map((violation) => violation.ruleId),
    ["branch-protection-disable", "direct-main-push"],
  );
});

test("ignores unrelated public docs", () => {
  const text = [
    "An example may reference projectId: prod-project-123 without being launch evidence.",
    "Never push directly to main.",
  ].join("\n");

  assert.deepEqual(scanText("docs/README.md", text), []);
});
