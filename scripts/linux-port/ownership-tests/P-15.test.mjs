import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
const OWNED = ["docs/linux-port/P15_ACCOUNT_BILLING_PROOF.md", "scripts/linux-port/lib/p15-account-billing-proof.mjs", "scripts/linux-port/run-p15-native-account-billing-probes.mjs", "scripts/linux-port/materialize-p15-account-billing-session.mjs", "scripts/linux-port/capture-p15-account-billing-proof.mjs", "scripts/linux-port/p15-account-billing-proof.test.mjs", "scripts/linux-port/product-validators/P-15.mjs", "scripts/linux-port/ownership-tests/P-15.test.mjs"];
test("P-15 standalone ownership is exact and fail closed", () => { for (const file of OWNED) assert.equal(fs.existsSync(path.join(ROOT, file)), true, `missing ${file}`); const p15 = []; for (const directory of ["docs/linux-port", "scripts/linux-port", "scripts/linux-port/lib", "scripts/linux-port/product-validators", "scripts/linux-port/ownership-tests"]) for (const name of fs.readdirSync(path.join(ROOT, directory))) if (/P-?15|p15/iu.test(name)) p15.push(path.relative(ROOT, path.join(ROOT, directory, name)).split(path.sep).join("/")); assert.deepEqual([...new Set(p15)].sort(), [...OWNED].sort()); });
