import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  P28_PROOF_FILENAME,
  P28_PROOF_ROLE,
  P28_RAW_FILES,
  P28_SESSION_FILENAME,
} from "../lib/p28-smarthub-proof.mjs";
import { validateProductRequirement } from "../product-validators/P-28.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

test("P-28 standalone ownership is exact and fail closed", async () => {
  assert.equal(P28_PROOF_ROLE, "feature.smarthub-installed");
  assert.equal(P28_PROOF_FILENAME, "p28-installed-smarthub-proof.json");
  assert.equal(P28_SESSION_FILENAME, "p28-installed-smarthub-session.json");
  assert.deepEqual([...P28_RAW_FILES].sort(), [
    "smarthub-controlled-atspi.json",
    "smarthub-controlled.png",
    "smarthub-degraded-atspi.json",
    "smarthub-degraded.png",
    "smarthub-discovered-atspi.json",
    "smarthub-discovered.png",
    "smarthub-marker.json",
    "smarthub-native-transcript.json",
    "smarthub-peer-manifest.json",
    "smarthub-recovered-atspi.json",
    "smarthub-recovered.png",
  ]);
  const capture = fs.readFileSync(
    path.join(ROOT, "scripts/linux-port/capture-p28-smarthub-proof.mjs"),
    "utf8",
  );
  const materializer = fs.readFileSync(
    path.join(ROOT, "scripts/linux-port/materialize-p28-smarthub-session.mjs"),
    "utf8",
  );
  const validator = fs.readFileSync(
    path.join(ROOT, "scripts/linux-port/product-validators/P-28.mjs"),
    "utf8",
  );
  assert.match(capture, /role: P28_PROOF_ROLE/u);
  assert.match(capture, /validateP28Proof/u);
  assert.match(materializer, /P28_RAW_FILES/u);
  assert.match(materializer, /validateP28InstalledSession/u);
  assert.match(validator, /P28_PROOF_ROLE/u);
  assert.match(validator, /validateP28Proof/u);
  await assert.rejects(
    validateProductRequirement({}),
    /release closure is not passed/u,
  );
});
