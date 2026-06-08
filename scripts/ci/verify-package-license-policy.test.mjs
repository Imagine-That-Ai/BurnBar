#!/usr/bin/env node
import assert from "node:assert/strict";
import test from "node:test";

import {
  PRODUCT_LICENSE,
  validatePackageLicensePolicy,
} from "./verify-package-license-policy.mjs";

const BOUNDARY_PACKAGE = "packages/e2ee-backend-policy/package.json";

test("allows the documented MIT upstream-boundary package", () => {
  const failures = validatePackageLicensePolicy([
    {
      file: "packages/libsignal-bridge/package.json",
      json: { name: "@openburnbar/libsignal-bridge", license: PRODUCT_LICENSE },
    },
    {
      file: BOUNDARY_PACKAGE,
      json: { name: "@openburnbar/e2ee-backend-policy", license: "MIT" },
    },
  ]);

  assert.deepEqual(failures, []);
});

test("rejects undocumented MIT packages", () => {
  const failures = validatePackageLicensePolicy([
    {
      file: "packages/accidental/package.json",
      json: { name: "@openburnbar/accidental", license: "MIT" },
    },
  ]);

  assert.match(
    failures.join("\n"),
    /packages\/accidental\/package\.json: expected license AGPL-3\.0-only/,
  );
});

test("rejects a renamed boundary package", () => {
  const failures = validatePackageLicensePolicy([
    {
      file: BOUNDARY_PACKAGE,
      json: { name: "@openburnbar/not-the-policy-package", license: "MIT" },
    },
  ]);

  assert.match(
    failures.join("\n"),
    /expected package name @openburnbar\/e2ee-backend-policy/,
  );
});

test("rejects Signal dependencies in the MIT boundary package", () => {
  const failures = validatePackageLicensePolicy([
    {
      file: BOUNDARY_PACKAGE,
      json: {
        name: "@openburnbar/e2ee-backend-policy",
        license: "MIT",
        dependencies: {
          "@signalapp/libsignal-client": "0.94.4",
        },
      },
    },
  ]);

  assert.match(failures.join("\n"), /must stay libsignal-free/);
  assert.match(failures.join("\n"), /@signalapp\/libsignal-client/);
});
