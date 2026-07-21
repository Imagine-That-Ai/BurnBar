import assert from "node:assert/strict";
import test from "node:test";
import { classifyEvent, classifyPaths, LANES } from "./classify-ci-impact.mjs";

test("documentation and ordinary workflow changes skip product suites", () => {
  const result = classifyPaths(["docs/CI.md", ".github/workflows/triage.yml"]);
  assert.equal(result.full, false);
  for (const lane of LANES) assert.equal(result[lane], false);
});

test("isolated tests select only their owning product", () => {
  const app = classifyPaths(["AgentLensTests/QuotaTests.swift"]);
  assert.equal(app.macos, true);
  assert.equal(app.mobile, false);
  const functions = classifyPaths(["functions/src/billing.test.ts"]);
  assert.equal(functions.functions, true);
  assert.equal(functions.macos, false);
});

test("shared Swift sources select every Swift consumer", () => {
  const result = classifyPaths(["OpenBurnBarCore/Sources/Quota.swift"]);
  assert.equal(result.macos, true);
  assert.equal(result.mobile, true);
  assert.equal(result.daemon, true);
  assert.equal(result.android, false);
});

test("domain-core transitive consumers select the Rust lane", () => {
  for (const path of [
    "functions/src/domainCorePricing.ts",
    "AgentLens/Services/ProviderQuota/ProviderQuotaMacBridge.swift",
    "android/openburnbar-domain-core/src/main/Test.kt",
  ]) {
    assert.equal(classifyPaths([path]).rust, true, path);
  }
});

test("dependency manifests and security or release workflows force full CI", () => {
  for (const path of [
    "Cargo.lock",
    "android/build.gradle.kts",
    ".github/workflows/deploy-production.yml",
    "governance/branch-protection.main.json",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, true, path);
    for (const lane of LANES)
      assert.equal(result[lane], true, `${path}:${lane}`);
  }
});

test("unknown and empty classifications fail closed", () => {
  assert.equal(classifyPaths(["mystery/new-surface.xyz"]).full, true);
  assert.equal(classifyPaths([]).full, true);
});

test("full-ci label and full-run events force all lanes", () => {
  assert.equal(
    classifyPaths(["docs/README.md"], { labels: ["FULL-CI"] }).full,
    true,
  );
  for (const eventName of ["schedule", "workflow_dispatch", "release"]) {
    assert.equal(classifyPaths(["docs/README.md"], { eventName }).full, true);
  }
});

test("merge-group uses its exact base and synthetic head", () => {
  const event = { merge_group: { base_sha: "base", head_sha: "candidate" } };
  const result = classifyEvent(event, "merge_group", (base, head) => {
    assert.equal(base, "base");
    assert.equal(head, "candidate");
    return ["android/app/src/main/Test.kt"];
  });
  assert.equal(result.android, true);
  assert.equal(result.macos, false);
});

test("unresolvable event diff fails closed", () => {
  const event = {
    pull_request: { base: { sha: "base" }, head: { sha: "head" }, labels: [] },
  };
  const result = classifyEvent(event, "pull_request", () => {
    throw new Error("missing");
  });
  assert.equal(result.full, true);
});
