import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  buildDeploymentIdentity,
  main,
} from "./create-domain-core-deployment-identity.mjs";
import { loadDomainCoreBuildProfiles } from "../lib/domain-core-build-profile.mjs";

const catalog = loadDomainCoreBuildProfiles(
  new URL("../../config/domain-core-build-profiles.json", import.meta.url),
);

test("console identity exactly binds repository, commit, tag, and public profile", () => {
  const identity = buildDeploymentIdentity({
    catalog,
    consumer: "console",
    commit: "a".repeat(40),
    tag: "v1.2.3+build.7",
  });
  assert.deepEqual(identity, {
    schemaVersion: 1,
    consumer: "console",
    target: "firebase-hosting-production",
    repository: "https://github.com/Imagine-That-Ai/BurnBar",
    commit: "a".repeat(40),
    tag: "v1.2.3+build.7",
    profile: {
      domain: "cloudVault",
      mode: "legacy",
      publicProfileSha256:
        "a9b582f5aaf8ec8d7f6de7a14e41c1d6aa588ee70c98cbcc8a46fed19c044c51",
    },
  });
});

test("console identity verification fails closed on stale hosted bytes", () => {
  const directory = mkdtempSync(
    join(tmpdir(), "domain-core-console-identity-"),
  );
  const output = join(directory, "identity.json");
  const args = [
    "node",
    "script",
    "--consumer",
    "console",
    "--commit",
    "a".repeat(40),
    "--tag",
    "v1.2.3",
    "--output",
    output,
  ];
  main(args);
  const stale = JSON.parse(readFileSync(output, "utf8"));
  stale.commit = "b".repeat(40);
  writeFileSync(output, `${JSON.stringify(stale)}\n`);
  assert.throws(
    () =>
      main([
        "node",
        "script",
        "--consumer",
        "console",
        "--commit",
        "a".repeat(40),
        "--tag",
        "v1.2.3",
        "--verify",
        output,
      ]),
    /deployed identity does not match/,
  );
});

test("console identity rejects unknown consumers, invalid commits, and invalid tags", () => {
  const base = {
    catalog,
    consumer: "console",
    commit: "a".repeat(40),
    tag: "v1.2.3",
  };
  assert.throws(
    () => buildDeploymentIdentity({ ...base, consumer: "functions" }),
    /only the console/,
  );
  assert.throws(
    () => buildDeploymentIdentity({ ...base, commit: "short" }),
    /full lowercase Git SHA/,
  );
  assert.throws(
    () => buildDeploymentIdentity({ ...base, tag: "main" }),
    /semantic v\* release tag/,
  );
  assert.throws(
    () => buildDeploymentIdentity({ ...base, tag: "v1.2.3-beta.1" }),
    /stable semantic v\* release tag/,
  );
});
