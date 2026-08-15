import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  classifyEvent,
  classifyPaths,
  DOMAIN_CORE_OWNED_PATH_GLOBS,
  gitDiff,
  LANES,
} from "./classify-ci-impact.mjs";

test("documentation and ordinary workflow changes skip product suites", () => {
  const result = classifyPaths(["docs/CI.md", ".github/workflows/triage.yml"]);
  assert.equal(result.full, false);
  for (const lane of LANES) assert.equal(result[lane], false);
});

test("launch-evidence attestation JSON is no-product (honest skip/require)", () => {
  for (const path of [
    "launch-evidence/libsignal-rust-core-bridge-v1.0.34.json",
    "launch-evidence/latest-agpl-store-legal-packet.json",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, false, path);
    for (const lane of LANES) assert.equal(result[lane], false, `${path}:${lane}`);
  }
});

test("isolated tests select only their owning product", () => {
  const app = classifyPaths(["AgentLensTests/QuotaTests.swift"]);
  assert.equal(app.macos, true);
  assert.equal(app.mobile, false);
  const functions = classifyPaths(["functions/src/billing.test.ts"]);
  assert.equal(functions.functions, true);
  assert.equal(functions.macos, false);
  const windows = classifyPaths([
    "windows/tests/managed-runtime/ManagedRuntimeTests.cs",
  ]);
  assert.equal(windows.full, false);
  for (const lane of LANES) assert.equal(windows[lane], false);
});

test("Safari extension paths select only the required Safari, macOS, and web lanes", () => {
  const native = classifyPaths([
    "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift",
  ]);
  assert.equal(native.full, false);
  assert.equal(native.macos, true);
  assert.equal(native.web, false);
  assert.equal(native.safari, true);
  for (const lane of LANES.filter(
    (lane) => lane !== "macos" && lane !== "safari",
  ))
    assert.equal(native[lane], false, `native:${lane}`);

  for (const path of [
    "extensions/safari/src/content/extract.ts",
    "scripts/test-openburnbar-safari-extension.sh",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, false, path);
    assert.equal(result.macos, true, path);
    assert.equal(result.web, true, path);
    assert.equal(result.safari, true, path);
    for (const lane of LANES.filter(
      (lane) => lane !== "macos" && lane !== "web" && lane !== "safari",
    ))
      assert.equal(result[lane], false, `${path}:${lane}`);
  }

  const fixtures = classifyPaths([
    "tools/safari-certification-fixtures/server.test.mjs",
  ]);
  assert.equal(fixtures.full, false);
  assert.equal(fixtures.safari, true);
  for (const lane of LANES.filter((lane) => lane !== "safari"))
    assert.equal(fixtures[lane], false, `fixture:${lane}`);
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
    "windows/tests/quota/ProviderQuotaTests.cs",
    "apps/console/lib/escrow.ts",
    "functions/src/health.ts",
  ]) {
    assert.equal(classifyPaths([path]).rust, true, path);
  }
});

test("the migrated Domain Core trigger policy routes every governed glob", () => {
  assert.equal(DOMAIN_CORE_OWNED_PATH_GLOBS.length, 184);
  for (const glob of DOMAIN_CORE_OWNED_PATH_GLOBS) {
    const representative = glob
      .replaceAll("**", "nested/owned.txt")
      .replaceAll("*", "owned")
      .replaceAll("?", "x");
    assert.equal(classifyPaths([representative]).rust, true, glob);
  }
  for (const path of [
    "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift",
    "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
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
    "windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj",
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

test("push uses the exact before and after commits", () => {
  const event = { before: "base", after: "head" };
  const result = classifyEvent(event, "push", (base, head) => {
    assert.equal(base, "base");
    assert.equal(head, "head");
    return ["docs/README.md"];
  });
  assert.equal(result.full, false);
  for (const lane of LANES) assert.equal(result[lane], false);
});

test("push diffs retain governed deletions alongside safe changes", (context) => {
  const repo = mkdtempSync(join(tmpdir(), "burnbar-ci-impact-"));
  context.after(() => rmSync(repo, { recursive: true, force: true }));
  execFileSync("git", ["init", "-q"], { cwd: repo });
  execFileSync("git", ["config", "user.name", "CI Test"], { cwd: repo });
  execFileSync("git", ["config", "user.email", "ci@example.invalid"], {
    cwd: repo,
  });
  // Temp fixture commits must not inherit the agent's global commit.gpgsign.
  execFileSync("git", ["config", "commit.gpgsign", "false"], { cwd: repo });
  const governed =
    "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift";
  mkdirSync(
    join(repo, "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels"),
    {
      recursive: true,
    },
  );
  writeFileSync(join(repo, governed), "governed\n");
  execFileSync("git", ["add", "."], { cwd: repo });
  execFileSync("git", ["commit", "-q", "-m", "base"], { cwd: repo });
  const base = execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: repo,
    encoding: "utf8",
  }).trim();
  rmSync(join(repo, governed));
  mkdirSync(join(repo, "docs"), { recursive: true });
  writeFileSync(join(repo, "docs/README.md"), "safe\n");
  execFileSync("git", ["add", "-A"], { cwd: repo });
  execFileSync("git", ["commit", "-q", "-m", "delete governed file"], {
    cwd: repo,
  });
  const head = execFileSync("git", ["rev-parse", "HEAD"], {
    cwd: repo,
    encoding: "utf8",
  }).trim();
  const paths = gitDiff(base, head, repo);
  assert.deepEqual(paths.sort(), [governed, "docs/README.md"].sort());
  const result = classifyEvent(
    { before: base, after: head },
    "push",
    (from, to) => gitDiff(from, to, repo),
  );
  assert.equal(result.rust, true);
  assert.equal(result.full, false);
});

test("push with an unavailable exact range fails closed to a full run", () => {
  const event = { before: "unavailable-base", after: "unavailable-head" };
  const attempted = [];
  const result = classifyEvent(event, "push", (base, head) => {
    attempted.push([base, head]);
    throw new Error("event commits are outside the shallow checkout");
  });
  // Only the exact before..after range is acceptable proof input; a partial
  // range such as HEAD^..HEAD would under-classify multi-commit pushes.
  assert.deepEqual(attempted, [["unavailable-base", "unavailable-head"]]);
  assert.equal(result.full, true);
  assert.equal(result.rust, true);
});

test("push with an unresolved all-zero boundary fails closed", () => {
  let diffCalled = false;
  const result = classifyEvent(
    { before: "0".repeat(40), after: "a".repeat(40) },
    "push",
    () => {
      diffCalled = true;
      return [];
    },
  );
  assert.equal(diffCalled, false);
  assert.equal(result.full, true);
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

test("shallow synthetic checkout falls back to merge parents", () => {
  const event = {
    pull_request: {
      base: { sha: "unavailable-base" },
      head: { sha: "unavailable-head" },
      labels: [],
    },
  };
  const result = classifyEvent(event, "pull_request", (base, head) => {
    if (base === "HEAD^1" && head === "HEAD^2") return ["website/src/page.ts"];
    throw new Error("event commits are outside the shallow checkout");
  });
  assert.equal(result.web, true);
  assert.equal(result.full, false);
});
