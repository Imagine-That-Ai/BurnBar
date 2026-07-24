import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { P35_PROOF_FILENAME, P35_PROOF_ROLE, P35_RAW_FILES, P35_SESSION_FILENAME } from "../lib/p35-diagnostics-support-proof.mjs";
import { validateProductRequirement } from "../product-validators/P-35.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");

test("P-35 standalone ownership is exact and fail closed", async () => {
  assert.equal(P35_PROOF_ROLE, "feature.diagnostics-support-installed");
  assert.equal(P35_PROOF_FILENAME, "p35-installed-diagnostics-support-proof.json");
  assert.equal(P35_SESSION_FILENAME, "p35-installed-diagnostics-support-session.json");
  assert.equal(P35_RAW_FILES.length, 11);
  const capture = fs.readFileSync(path.join(ROOT, "scripts/linux-port/capture-p35-diagnostics-support-proof.mjs"), "utf8");
  const materializer = fs.readFileSync(path.join(ROOT, "scripts/linux-port/materialize-p35-diagnostics-support-session.mjs"), "utf8");
  const runner = fs.readFileSync(path.join(ROOT, "scripts/linux-port/run-p35-native-diagnostics-probes.mjs"), "utf8");
  const validator = fs.readFileSync(path.join(ROOT, "scripts/linux-port/product-validators/P-35.mjs"), "utf8");
  assert.match(capture, /role: P35_PROOF_ROLE/u);
  assert.match(materializer, /P35_RAW_FILES/u);
  assert.match(runner, /createP35ProductionDependencies/u);
  assert.match(runner, /Export redacted diagnostics/u);
  assert.match(runner, /OPENAI_API_KEY: "p35-planted-openai-secret"/u);
  assert.match(validator, /validateP35Proof/u);
  for (const forbidden of ["product-validation-registry", "run-linux-product-proof-workflow", "preflight", "audit"]) assert.doesNotMatch(runner + capture + materializer, new RegExp(forbidden, "u"));
  await assert.rejects(validateProductRequirement({}), /release closure is not passed/u);
});
