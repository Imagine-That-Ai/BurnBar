#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const packageJson = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
const scripts = packageJson.scripts ?? {};

assert.equal(
  scripts.build,
  scripts["build:offline"],
  "website build must use the static/offline rundown path"
);
assert.doesNotMatch(
  scripts.build,
  /\brun-research\.mjs\b/u,
  "website build must not run live router research"
);
assert.doesNotMatch(
  scripts.build,
  /\bfunctions\/lib\b/u,
  "website build must not import generated Functions artifacts"
);
assert.doesNotMatch(
  scripts.build,
  /--env-file-if-exists=\.env/u,
  "website build must not load local env files"
);
assert.match(
  scripts.research,
  /\brun-research\.mjs\b/u,
  "live router research should remain available as an explicit command"
);
assert.match(
  scripts.verify,
  /\bnpm run test:build-script\b/u,
  "website verify must keep the build-script boundary test enabled"
);

console.log(
  "PASS website build uses checked-in/static rundown data; live research remains explicit."
);
