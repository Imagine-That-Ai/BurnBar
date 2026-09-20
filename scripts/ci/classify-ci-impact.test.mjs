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

test("plugins/openburnbar sources select only the cheap web lane", () => {
  for (const path of [
    "plugins/openburnbar/scripts/validate.mjs",
    "plugins/openburnbar/.cursor-plugin/plugin.json",
    "plugins/openburnbar/skills/openburnbar-operator/SKILL.md",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, false, path);
    assert.equal(result.web, true, path);
    for (const lane of LANES) {
      if (lane !== "web") assert.equal(result[lane], false, `${path}:${lane}`);
    }
  }
});

test("a plugin package.json still forces full CI", () => {
  const result = classifyPaths(["plugins/openburnbar/package.json"]);
  assert.equal(result.full, true);
  for (const lane of LANES) assert.equal(result[lane], true);
});

test("isolated tests select only their owning product", () => {
  const app = classifyPaths(["AgentLensTests/QuotaTests.swift"]);
  assert.equal(app.macos, true);
  assert.equal(app.mobile, false);
  const mobile = classifyPaths(["OpenBurnBarMobile/Foo.swift"]);
  assert.equal(mobile.mobile, true);
  assert.equal(mobile.macos, false);
  const functions = classifyPaths(["functions/src/billing.test.ts"]);
  assert.equal(functions.functions, true);
  assert.equal(functions.macos, false);
  const windows = classifyPaths([
    "windows/tests/managed-runtime/ManagedRuntimeTests.cs",
  ]);
  assert.equal(windows.full, false);
  for (const lane of LANES) assert.equal(windows[lane], false);
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
    // Every governed path stays owned by the domain core -- product paths run
    // the native fleet, evidence machinery runs the promotion contracts. What
    // no governed glob may ever do is fall through to SAFE or ambiguous.
    const result = classifyPaths([representative]);
    assert.equal(
      result.rust || result.rustTooling,
      true,
      `${glob} must stay domain-core owned`,
    );
  }
  // Machinery routes to the contracts lane only: no macOS fleet for verifier,
  // config, or evidence-doc edits.
  for (const path of [
    "scripts/ci/verify-domain-core-control-plane.mjs",
    "scripts/lib/domain-core-activation.mjs",
    "scripts/ops/create-domain-core-stable-receipt.py",
    "config/domain-core-control-plane-manifest.json",
    "config/domain-core-build-profiles.json",
    "tests/test_domain_core_union_gate.py",
    ".github/workflows/domain-core-ios-release-evidence.yml",
    "docs/SHARED_RUST_DOMAIN_CORE_ROADMAP.md",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.rustTooling, true, `${path} -> rustTooling`);
    assert.equal(result.rust, false, `${path} must not wake the native fleet`);
  }
  // Product paths still run the fleet.
  for (const path of [
    "crates/openburnbar-domain-core/domain-ffi/src/lib.rs",
    "Vendor/openburnbar-domain-core.aar",
    "OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/x.swift",
    "windows/app/OpenBurnBar.App.Configuration/DomainCoreBuildProfileResolver.cs",
    ".github/workflows/domain-core.yml",
  ]) {
    assert.equal(classifyPaths([path]).rust, true, path);
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
    "packages/libsignal-bridge/package-lock.json",
    "package-lock.json",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, true, path);
    for (const lane of LANES)
      assert.equal(result[lane], true, `${path}:${lane}`);
  }
});

test("signal-envelope-contracts npm lockfile selects functions, not macos", () => {
  const result = classifyPaths([
    "packages/signal-envelope-contracts/package-lock.json",
    "packages/signal-envelope-contracts/package.json",
  ]);
  assert.equal(result.full, false);
  assert.equal(result.reason, "owned-paths");
  assert.equal(result.functions, true);
  assert.equal(result.macos, false);
  assert.equal(result.mobile, false);
  assert.equal(result.android, false);
  assert.equal(result.rust, false);
  assert.equal(result.daemon, false);
  assert.equal(result.web, false);
  assert.equal(result.console, false);
});

test("signal-envelope-contracts non-manifest files stay fail-closed", () => {
  for (const path of [
    "packages/signal-envelope-contracts/src/index.ts",
    "packages/signal-envelope-contracts/src/index.test.ts",
    "packages/signal-envelope-contracts/eslint.config.mjs",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, true, path);
    assert.notEqual(result.reason, "owned-paths", path);
    for (const lane of LANES)
      assert.equal(result[lane], true, `${path}:${lane}`);
  }
});

test("signal-envelope-contracts mixed with AgentLens still wakes macos", () => {
  const result = classifyPaths([
    "packages/signal-envelope-contracts/package-lock.json",
    "AgentLens/Services/LogParser/GrokParser.swift",
  ]);
  assert.equal(result.full, false);
  assert.equal(result.functions, true);
  assert.equal(result.macos, true);
  assert.equal(result.mobile, false);
});

test("safari extension npm manifests select macos, not a full run", () => {
  const result = classifyPaths([
    "extensions/safari/package-lock.json",
    "extensions/safari/package.json",
  ]);
  assert.equal(result.full, false);
  assert.equal(result.reason, "owned-paths");
  assert.equal(result.macos, true);
  assert.equal(result.mobile, false);
  assert.equal(result.android, false);
  assert.equal(result.rust, false);
  assert.equal(result.daemon, false);
  assert.equal(result.functions, false);
  assert.equal(result.web, false);
  assert.equal(result.console, false);
});

test("safari extension source and built bundle select macos", () => {
  for (const path of [
    "extensions/safari/src/background/controller.ts",
    "extensions/safari/src/shared/protocol.ts",
    "extensions/safari/test/controller.serviceWorker.test.ts",
    "extensions/safari/tsconfig.background.json",
    "extensions/safari/dist/background.js",
    "OpenBurnBarSafariExtension/SafariWebExtensionHandler.swift",
  ]) {
    const result = classifyPaths([path]);
    assert.equal(result.full, false, path);
    assert.equal(result.reason, "owned-paths", path);
    assert.equal(result.macos, true, path);
    assert.equal(result.mobile, false, path);
    assert.equal(result.web, false, path);
  }
});

test("external Safari build inputs reach the macos lane", () => {
  // build.mjs copies these into extensions/safari/dist; if a change to one
  // does not select macos, safari-extension-fast never runs and the stale
  // bundle sails past the byte-for-byte dist gate.
  const icon = classifyPaths(["extensions/openburnbar/media/app-icon-128.png"]);
  assert.equal(icon.macos, true);
  assert.equal(icon.web, true);

  const logo = classifyPaths([
    "AgentLens/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.svg",
  ]);
  assert.equal(logo.macos, true);

  // design-tokens has no lane of its own, so it fails closed to a full run,
  // which already includes macos.
  const tokens = classifyPaths(["packages/design-tokens/dist/css/pensieve.css"]);
  assert.equal(tokens.macos, true);
});

test("safari extension manifests mixed with functions wake both lanes", () => {
  const result = classifyPaths([
    "extensions/safari/package.json",
    "functions/src/index.ts",
  ]);
  assert.equal(result.full, false);
  assert.equal(result.macos, true);
  assert.equal(result.functions, true);
  assert.equal(result.mobile, false);
});

test("this classifier edit still classifies as full", () => {
  const result = classifyPaths(["scripts/ci/classify-ci-impact.mjs"]);
  assert.equal(result.full, true);
  assert.equal(result.reason, "shared-or-sensitive-path");
  for (const lane of LANES) assert.equal(result[lane], true, lane);
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
