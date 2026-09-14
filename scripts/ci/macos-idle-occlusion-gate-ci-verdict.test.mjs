import assert from "node:assert/strict";
import test from "node:test";
import { ciVerdict } from "./macos-idle-occlusion-gate-ci-verdict.mjs";

test("passed and skipped evidence are green", () => {
  assert.deepEqual(ciVerdict({ status: "passed" }), { exitCode: 0, reason: "passed" });
  assert.deepEqual(ciVerdict({ status: "skipped" }), { exitCode: 0, reason: "skipped" });
});

test("VirtualMac helper-timeout is infra skip, not a budget red", () => {
  const evidence = {
    status: "infra-failed",
    failureClass: "infra",
    reasonCode: "helper-timeout",
    machineIdentity: { hardware: { model: "VirtualMac2,1" } },
  };
  assert.deepEqual(ciVerdict(evidence), { exitCode: 0, reason: "virtual-mac-infra" });
});

test("real-Mac infra and budget failures stay red", () => {
  assert.equal(
    ciVerdict({
      status: "infra-failed",
      failureClass: "infra",
      machineIdentity: { hardware: { model: "Mac16,8" } },
    }).exitCode,
    1,
  );
  assert.equal(
    ciVerdict({
      status: "failed",
      failureClass: "budget",
      machineIdentity: { hardware: { model: "VirtualMac2,1" } },
    }).exitCode,
    1,
  );
});

test("missing evidence is red", () => {
  assert.equal(ciVerdict(null).exitCode, 1);
  assert.equal(ciVerdict({}).exitCode, 1);
});
