import assert from "node:assert/strict";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";

import {
  deriveDomainCoreFunctionsTargets,
  verifyDomainCoreFunctionsTargetInventory,
} from "./verify-domain-core-functions-target-inventory.mjs";

const ROOT = resolve(new URL("../..", import.meta.url).pathname);
const INVENTORY = JSON.parse(
  readFileSync(
    new URL(
      "../../config/domain-core-functions-relevant-targets.json",
      import.meta.url,
    ),
  ),
);

test("derives the protected target inventory from the local pricing import graph", () => {
  assert.deepEqual(deriveDomainCoreFunctionsTargets(ROOT), INVENTORY.targets);
  assert.deepEqual(
    verifyDomainCoreFunctionsTargetInventory({
      repoRoot: ROOT,
      inventory: INVENTORY,
    }).targets,
    INVENTORY.targets,
  );
});

test("a new exported pricing caller fails closed until provider readback covers it", (context) => {
  const root = mkdtempSync(join(tmpdir(), "domain-core-functions-graph-"));
  context.after(() => rmSync(root, { recursive: true, force: true }));
  cpSync(resolve(ROOT, "functions"), resolve(root, "functions"), {
    recursive: true,
    filter: (source) => !source.includes("node_modules") && !source.includes("/lib"),
  });
  const caller = resolve(root, "functions/src/newPricingCaller.ts");
  writeFileSync(
    caller,
    'import "./domainCorePricing.js";\nexport const newPricingCaller = () => undefined;\n',
  );
  const index = resolve(root, "functions/src/index.ts");
  const newSpecifier = "./newPricing" + "Caller.js";
  writeFileSync(
    index,
    `${readFileSync(index, "utf8")}\nexport { newPricingCaller } from "${newSpecifier}";\n`,
  );
  assert.throws(
    () =>
      verifyDomainCoreFunctionsTargetInventory({
        repoRoot: root,
        inventory: INVENTORY,
      }),
    /newPricingCaller/u,
  );
});
