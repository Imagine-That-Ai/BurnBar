import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP30NativePetProbes } from "./run-p30-native-pet-probes.mjs";

function fixture(displayServer = "X11") {
  const base = path.join(process.cwd(), ".tmp/p30-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "probe-"));
  const rawOutputDir = path.join(root, "raw");
  const homeDir = path.join(root, "home");
  fs.mkdirSync(homeDir, { mode: 0o700 });
  return {
    root,
    options: {
      rawOutputDir,
      homeDir,
      environmentId:
        displayServer === "X11"
          ? "ubuntu-24.04-gnome-x11-aarch64"
          : "ubuntu-24.04-gnome-wayland-aarch64",
      desktop: "GNOME",
      displayServer,
      marker: "p30-fedcba0987654321",
      targetHead: "1".repeat(40),
      candidateRunId: "303030",
      candidateArtifactDigest: `sha256:${"3".repeat(64)}`,
      packageVersion: "1.2.3",
      manifestSha256: "4".repeat(64),
      manifestSignatureSha256: "5".repeat(64),
    },
  };
}

function dependencies(
  value,
  { failAction = null, cleanupFailure = false } = {},
) {
  let pid = 3000;
  let alive = false;
  let launches = 0;
  let globalSummons = 0;
  const write = (file, document) => {
    fs.writeFileSync(file, `${JSON.stringify(document)}\n`, { mode: 0o600 });
    return document;
  };
  const status = (mode) => {
    const texts = {
      summon: "Contained preview summoned in this window.",
      select: "Contained pet selected in this window.",
      clear: "Contained pet selection cleared.",
      keyboard:
        "Contained preview moved with the keyboard (16,16). Press Home to reset.",
      reset:
        "Contained preview moved with the keyboard (0,0). Press Home to reset.",
      pointer:
        "Contained preview moved with pointer drag (50,30). Press Home to reset.",
    };
    return {
      producer: "openburnbar-p30-atspi-live-v1",
      application: "OpenBurnBar",
      capturedAt: new Date().toISOString(),
      focusedName: "Pet companion contained preview",
      statusText: texts[mode] ?? "ready",
      ariaKeyshortcuts:
        value.options.displayServer === "X11"
          ? "Ctrl+Alt+Super+P"
          : "unavailable-on-contained-fallback",
      namedNodes: Array.from({ length: 7 }, (_, index) => ({
        name: `node-${index}`,
        role: "section",
        actions: [],
      })),
    };
  };
  return {
    platform: "linux",
    installedVerifier() {},
    executableVerifier() {},
    packageIdentity: () => ({
      packageManager: "dpkg",
      packageName: "openburnbar",
      packageOwned: true,
    }),
    desktopProcessIDs: () => (alive ? [pid] : []),
    daemonActive: () => true,
    runtimeManifest: () => ({
      schemaVersion: 1,
      capabilities: [
        {
          id: "pet.overlay",
          state:
            value.options.displayServer === "X11" ? "available" : "degraded",
        },
      ],
    }),
    async launch() {
      launches += 1;
      pid = launches === 1 ? 3000 : 3001;
      alive = true;
      return pid;
    },
    async terminate() {
      alive = false;
      if (cleanupFailure) throw new Error("forced cleanup failure");
    },
    async route() {},
    async action(mode, output) {
      if (mode === failAction) throw new Error(`forced ${mode}`);
      return write(output, status(mode));
    },
    screenshot(file) {
      fs.writeFileSync(
        file,
        Buffer.alloc(
          1024,
          launches + globalSummons + path.basename(file).length,
        ),
        { mode: 0o600 },
      );
    },
    async globalSummon() {
      globalSummons += 1;
      return { id: "42", alwaysOnTop: true };
    },
    metrics: () => ({ globalSummons, launches, alive }),
  };
}

test("P-30 native probe exercises the X11 overlay and restores exact state", async () => {
  const value = fixture();
  const deps = dependencies(value);
  try {
    const result = await runP30NativePetProbes(value.options, deps);
    assert.equal(result.transcript.compositor.mode, "x11-native-overlay");
    assert.equal(result.transcript.interactions.clickThrough.enabled, true);
    assert.deepEqual(deps.metrics(), {
      globalSummons: 1,
      launches: 2,
      alive: false,
    });
    assert.equal(
      fs.existsSync(path.join(value.options.rawOutputDir, "pet-marker.json")),
      true,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 native probe keeps Wayland on the contained fallback", async () => {
  const value = fixture("Wayland");
  const deps = dependencies(value);
  try {
    const result = await runP30NativePetProbes(value.options, deps);
    assert.equal(
      result.transcript.compositor.mode,
      "wayland-contained-fallback",
    );
    assert.equal(result.transcript.interactions.summon.globalShortcut, false);
    assert.equal(result.transcript.interactions.clickThrough.supported, false);
    assert.equal(deps.metrics().globalSummons, 0);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 native probe rejects optimistic Wayland capability", async () => {
  const value = fixture("Wayland");
  const deps = dependencies(value);
  deps.runtimeManifest = () => ({
    capabilities: [{ id: "pet.overlay", state: "available" }],
  });
  try {
    await assert.rejects(
      runP30NativePetProbes(value.options, deps),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((item) =>
          /Wayland runtime capability must fail closed/u.test(item.message),
        ),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 native probe aggregates interaction and cleanup failures", async () => {
  const value = fixture();
  const deps = dependencies(value, {
    failAction: "select",
    cleanupFailure: true,
  });
  try {
    await assert.rejects(
      runP30NativePetProbes(value.options, deps),
      (error) =>
        error instanceof AggregateError &&
        error.errors.some((item) => /forced select/u.test(item.message)) &&
        error.errors.some((item) => /cleanup/u.test(item.message)),
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-30 native probe refuses an ambiguous preexisting desktop", async () => {
  const value = fixture();
  const deps = dependencies(value);
  deps.desktopProcessIDs = () => [99];
  try {
    await assert.rejects(
      runP30NativePetProbes(value.options, deps),
      /no preexisting/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
