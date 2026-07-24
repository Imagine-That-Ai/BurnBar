import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  P16_PROOF_FILENAME,
  P16_PROOF_ROLE,
  P16_RAW_FILES,
  P16_SESSION_FILENAME,
} from "../lib/p16-cloud-devices-proof.mjs";
import { validateProductRequirement } from "../product-validators/P-16.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../..",
);

test("P-16 standalone ownership is exact and fail closed", async () => {
  assert.equal(P16_PROOF_ROLE, "feature.cloud-devices-installed");
  assert.equal(P16_PROOF_FILENAME, "p16-installed-cloud-devices-proof.json");
  assert.equal(
    P16_SESSION_FILENAME,
    "p16-installed-cloud-devices-session.json",
  );
  assert.equal(P16_RAW_FILES.length, 15);
  assert.deepEqual(
    P16_RAW_FILES.slice(0, 2),
    [
      "cloud-devices-coordination-request.json",
      "cloud-devices-revocation-ready.json",
    ],
  );
  const sources = [
    "scripts/linux-port/run-p16-native-cloud-devices-probes.mjs",
    "scripts/linux-port/materialize-p16-cloud-devices-session.mjs",
    "scripts/linux-port/capture-p16-cloud-devices-proof.mjs",
    "scripts/linux-port/capture-p16-physical-ipad-trust-cycle.sh",
    "scripts/linux-port/p16-physical-ipad-coordination.mjs",
    "OpenBurnBarMobileTests/P16PhysicalIPadTrustCycleTests.swift",
  ].map((file) => fs.readFileSync(path.join(ROOT, file), "utf8"));
  assert.match(sources[0], /createP16ProductionDependencies/u);
  assert.match(sources[0], /physical-ipad/u);
  assert.match(sources[1], /P16_RAW_FILES/u);
  assert.match(sources[2], /role: P16_PROOF_ROLE/u);
  assert.match(sources[3], /OPENBURNBAR_P16_PHASE/u);
  assert.match(sources[4], /validateRevokeReady/u);
  assert.match(sources[5], /UIDevice\.current\.userInterfaceIdiom == \.pad/u);
  for (const forbidden of [
    "product-validation-registry",
    "run-linux-product-proof-workflow",
    "parity-certification-preflight",
    "LINUX_MACOS_PARITY_INDEPENDENT_AUDIT",
  ])
    assert.doesNotMatch(sources.join("\n"), new RegExp(forbidden, "u"));
  await assert.rejects(
    validateProductRequirement({}),
    /release closure is not passed/u,
  );
});
