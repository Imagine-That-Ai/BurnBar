import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { captureP25NativeUpdatePhase } from "./run-p25-native-update-probes.mjs";

function fixture(phase) {
  const base = path.join(process.cwd(), ".tmp/p25-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, `${phase}-`));
  const rawOutputDir = path.join(root, "raw");
  fs.mkdirSync(rawOutputDir, { mode: 0o700 });
  return {
    root,
    options: {
      rawOutputDir,
      phase,
      expectedVersion: phase === "available" ? "1.2.2" : "1.2.3",
      packageChannel: "deb",
      environmentId: "ubuntu-24.04-gnome-x11-aarch64",
      targetHead: "1".repeat(40),
      candidateRunId: "252525",
      candidateArtifactDigest: `sha256:${"2".repeat(64)}`,
      packageVersion: "1.2.3",
      manifestSha256: "3".repeat(64),
      manifestSignatureSha256: "4".repeat(64),
      installedPackageSha256: "5".repeat(64),
      installedManifestSha256: "6".repeat(64),
      installedManifestSignatureSha256: "7".repeat(64),
      authenticatedReleaseCommit: "8".repeat(40),
      compositor: "Mutter",
    },
  };
}
function tree(phase, missingAction = false) {
  const version = phase === "available" ? "1.2.2" : "1.2.3";
  const common = [
    "Updates",
    "Package channel",
    "apt/dpkg",
    `Shell ${version}`,
    `Daemon ${version}`,
  ];
  const names =
    phase === "available"
      ? [
          ...common,
          "OpenBurnBar 1.2.3 is available",
          "Ed25519 verified feed",
          "Feed published less than a minute ago · signature verified",
          "The shell never runs package-manager commands or replaces distro-owned files.",
          ...(missingAction ? [] : ["Open signed download"]),
        ]
      : phase === "current"
        ? [
            ...common,
            "OpenBurnBar is up to date",
            "Ed25519 verified feed",
            "Feed published less than a minute ago · signature verified",
            "The shell never runs package-manager commands or replaces distro-owned files.",
          ]
        : phase === "error"
          ? [...common, "Update metadata rejected", "Check again"]
          : [...common, "Restart guidance"];
  return {
    nodes: names.map((name) => ({
      name,
      states: name === "Open signed download" ? ["enabled", "sensitive"] : [],
    })),
  };
}
function dependencies(options, missingAction = false) {
  let restartCount = 0;
  let pid = 2500;
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    packageFacts: () => ({
      channel: "deb",
      manager: "apt",
      owner: "apt/dpkg",
      version: options.expectedVersion,
    }),
    restart: () => {
      restartCount += 1;
    },
    restartCount: () => restartCount,
    ui: {
      async launch() {
        pid += 1;
        return { pid };
      },
      snapshot() {
        return tree(options.phase, missingAction);
      },
      async activate() {
        return { activation: { action: "click" } };
      },
      screenshot(file) {
        fs.writeFileSync(file, Buffer.alloc(2048, options.phase.length));
      },
      async stop() {},
    },
  };
}

test("P-25 native probe captures available, current, fail-closed error, and restart states", async () => {
  for (const phase of ["available", "current", "error", "restart"]) {
    const value = fixture(phase);
    const deps = dependencies(value.options);
    try {
      const result = await captureP25NativeUpdatePhase(value.options, deps);
      assert.equal(result.phase, phase);
      assert.equal(result.rollbackClaimed, false);
      assert.equal(
        result.provenance.packageSha256,
        value.options.installedPackageSha256,
      );
      assert.equal(result.action?.packageMutation ?? false, false);
      if (phase === "restart") assert.equal(deps.restartCount(), 1);
      assert.ok(
        fs.statSync(
          path.join(value.options.rawOutputDir, `updates-${phase}.png`),
        ).size > 1024,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-25 native probe rejects an available state without an enabled signed action", async () => {
  const value = fixture("available");
  try {
    await assert.rejects(
      captureP25NativeUpdatePhase(
        value.options,
        dependencies(value.options, true),
      ),
      /signed download action is not enabled/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
