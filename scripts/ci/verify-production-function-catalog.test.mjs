import test from "node:test";
import assert from "node:assert/strict";
import { extractFunctionNames, verifyRequiredFunctions } from "./verify-production-function-catalog.mjs";

test("extractFunctionNames accepts Firebase result envelopes and regional ids", () => {
  const names = extractFunctionNames({
    result: [
      { id: "us-central1/issueLinuxAppCheckChallenge" },
      { name: "projects/burnbar/locations/us-central1/functions/mintLinuxAppCheckToken" },
      { exportedName: "registerLinuxAppCheckDevice" },
    ],
  });
  assert.deepEqual([...names].sort(), [
    "issueLinuxAppCheckChallenge",
    "mintLinuxAppCheckToken",
    "registerLinuxAppCheckDevice",
  ]);
});

test("verification fails closed when one parity callable is absent", () => {
  const result = verifyRequiredFunctions({
    result: ["issueLinuxAppCheckChallenge", "registerLinuxAppCheckDevice"],
  });
  assert.equal(result.passed, false);
  assert.deepEqual(result.missing, [
    "approveLinuxAppCheckDevice",
    "listLinuxAppCheckDevices",
    "revokeLinuxAppCheckDevice",
    "mintLinuxAppCheckToken",
  ]);
});

test("verification passes only with the complete Linux App Check surface", () => {
  const result = verifyRequiredFunctions({
    result: [
      { id: "us-central1/issueLinuxAppCheckChallenge" },
      { id: "us-central1/registerLinuxAppCheckDevice" },
      { id: "us-central1/approveLinuxAppCheckDevice" },
      { id: "us-central1/listLinuxAppCheckDevices" },
      { id: "us-central1/revokeLinuxAppCheckDevice" },
      { id: "us-central1/mintLinuxAppCheckToken" },
    ],
  });
  assert.equal(result.passed, true);
  assert.deepEqual(result.missing, []);
});

test("malformed function-list envelopes are rejected", () => {
  assert.throws(() => extractFunctionNames({}), /must contain a result array/);
});
