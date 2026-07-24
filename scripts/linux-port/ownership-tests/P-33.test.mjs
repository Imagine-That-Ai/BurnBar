import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { P33_PROOF_FILENAME, P33_PROOF_ROLE, P33_RAW_FILES, P33_SESSION_FILENAME, P33_STATES } from "../lib/p33-reliability-proof.mjs";
import { validateProductRequirement } from "../product-validators/P-33.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

test("P-33 standalone ownership is exact and fail closed", async () => {
  assert.equal(P33_PROOF_ROLE, "feature.reliability-installed");
  assert.equal(P33_PROOF_FILENAME, "p33-installed-reliability-proof.json");
  assert.equal(P33_SESSION_FILENAME, "p33-installed-reliability-session.json");
  assert.deepEqual(P33_STATES, ["healthy", "degraded", "recovered", "relaunched"]);
  assert.equal(P33_RAW_FILES.length, 10);
  const capture = fs.readFileSync(path.join(ROOT, "scripts/linux-port/capture-p33-reliability-proof.mjs"), "utf8");
  const materializer = fs.readFileSync(path.join(ROOT, "scripts/linux-port/materialize-p33-reliability-session.mjs"), "utf8");
  const runner = fs.readFileSync(path.join(ROOT, "scripts/linux-port/run-p33-native-reliability-probes.mjs"), "utf8");
  const validator = fs.readFileSync(path.join(ROOT, "scripts/linux-port/product-validators/P-33.mjs"), "utf8");
  assert.match(capture, /role: P33_PROOF_ROLE/u);
  assert.match(materializer, /P33_RAW_FILES/u);
  assert.match(runner, /createP33ProductionDependencies/u);
  assert.match(runner, /subscription-resume/u);
  assert.match(runner, /systemctl.*suspend/us);
  assert.match(runner, /30 \* 60_000/u);
  assert.match(validator, /validateP33Proof/u);
  for (const forbidden of ["product-validation-registry", "run-linux-product-proof-workflow", "preflight", "audit"]) assert.doesNotMatch(runner + capture + materializer, new RegExp(forbidden, "u"));
  await assert.rejects(validateProductRequirement({}), /release closure is not passed/u);
});
