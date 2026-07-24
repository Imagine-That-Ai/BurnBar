import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  runP29InstalledProductionWorkflow,
  runP29InstalledTextExpansionWorkflow,
  validateP29WorkflowPaths,
} from "./run-p29-installed-text-expansion-workflow.mjs";

const PRODUCTION_SOURCE = fs.readFileSync(
  "scripts/linux-port/run-p29-installed-text-expansion-workflow.mjs",
  "utf8",
);

const IDENTITY = {
  environmentId: "ubuntu-24.04-gnome-x11-x86_64",
  targetHead: "a".repeat(40),
  candidateRunId: "29",
  candidateArtifactDigest: `sha256:${"b".repeat(64)}`,
  packageVersion: "1.2.3",
  manifestSha256: "c".repeat(64),
  manifestSignatureSha256: "d".repeat(64),
};
function fixture() {
  const base = path.join(process.cwd(), ".tmp/p29-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  fs.chmodSync(root, 0o700);
  const options = {
    rawOutputDir: path.join(root, "raw"),
    supportDir: path.join(root, "support"),
    homeDir: path.join(root, "home"),
    socketPath: path.join(root, "support/daemon.sock"),
    tokenFile: path.join(root, "support/token"),
    indexDatabase: path.join(root, "support/index.sqlite"),
    ...IDENTITY,
  };
  for (const directory of [
    options.rawOutputDir,
    options.supportDir,
    options.homeDir,
  ])
    fs.mkdirSync(directory, { mode: 0o700 });
  fs.writeFileSync(options.tokenFile, "e".repeat(64), { mode: 0o600 });
  return { root, options };
}
function dependencies(options, cleanupFailure = false) {
  const original = { schemaVersion: 1, snippets: [], consent: null };
  let snapshot = structuredClone(original);
  let storeBackup = structuredClone(original);
  let corrupt = false;
  let key = true;
  let restored = 0;
  const now = Date.parse("2026-07-20T20:00:00.000Z");
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => {},
    marker: "p29-0123456789abcdef",
    clock: (() => {
      let offset = 0;
      return () => new Date(now + (offset += 1000));
    })(),
    daemon: {
      async prepare() {
        return { active: true };
      },
      async restart() {},
      async restore() {
        restored += 1;
        if (cleanupFailure) throw new Error("forced daemon restore");
      },
    },
    rpc: {
      async snapshot() {
        if (corrupt || !key)
          throw new Error(corrupt ? "corrupt store" : "missing key");
        return structuredClone(snapshot);
      },
      async consent(value) {
        snapshot.consent = {
          ...value,
          acknowledgedAt: new Date(now).toISOString(),
        };
        return { consent: snapshot.consent };
      },
      async upsert(item) {
        const index = snapshot.snippets.findIndex(
          (entry) => entry.id === item.id,
        );
        const next = {
          ...item,
          revision:
            index < 0
              ? Math.max(1, item.revision)
              : snapshot.snippets[index].revision + 1,
        };
        if (index < 0) snapshot.snippets.push(next);
        else snapshot.snippets[index] = next;
        storeBackup = structuredClone(snapshot);
        return structuredClone(next);
      },
      async delete(id) {
        snapshot.snippets = snapshot.snippets.filter((item) => item.id !== id);
        storeBackup = structuredClone(snapshot);
        return structuredClone(snapshot);
      },
      async engineStatus() {
        return {
          backend: "ibus",
          engineID: "org.openburnbar.TextExpansion",
          registration: "registered",
          supportsExternalExpansion: true,
          secureFieldPolicy: "deny-unless-inspectable-and-explicitly-nonsecure",
          manifestSha256: "f".repeat(64),
        };
      },
      async engineStart() {
        return { state: "ready" };
      },
      async engineStop() {
        return { state: "stopped" };
      },
    },
    keyring: {
      async status() {
        return { backend: "secret-service", reachable: true };
      },
      async removeKey() {
        key = false;
      },
      async restoreKey() {
        key = true;
      },
    },
    store: {
      async inspect() {
        return {
          path: path.join(options.supportDir, "text-expansion-v1.obbsealed"),
          mode: "0600",
          ownerUid: process.getuid(),
          symlink: false,
          containsPlaintext: false,
          ciphertextSha256: "9".repeat(64),
        };
      },
      async corrupt() {
        storeBackup = structuredClone(snapshot);
        corrupt = true;
      },
      async restore() {
        corrupt = false;
        snapshot = structuredClone(storeBackup);
      },
      async restoreOriginal() {
        corrupt = false;
        snapshot = structuredClone(original);
      },
    },
    ui: {
      async capture(state) {
        const screenshot = path.join(
          options.rawOutputDir,
          `text-expansion-${state}.png`,
        );
        const accessibility = path.join(
          options.rawOutputDir,
          `text-expansion-${state}-atspi.json`,
        );
        fs.writeFileSync(screenshot, Buffer.alloc(2048, state.length), {
          mode: 0o600,
        });
        fs.writeFileSync(
          accessibility,
          `${JSON.stringify({ application: ["expanded", "secure-denied"].includes(state) ? "OpenBurnBar P29 IBus Probe" : "OpenBurnBar", route: ["expanded", "secure-denied"].includes(state) ? "ibus-field-probe" : "text-expansion", pass: true, nodes: Array.from({ length: 8 }, (_, index) => ({ name: `${state}-${index}`, role: "entry" })) }, null, 2)}\n`,
          { mode: 0o600 },
        );
        return { screenshot, accessibility };
      },
      async expandThroughInputMethod({ marker, replacement }) {
        return {
          application: "OpenBurnBar P29 IBus Probe",
          engine: "openburnbar",
          fieldRole: "text",
          marker,
          probePID: 2900,
          previousEngine: "xkb:us::eng",
          before: "",
          after: `${replacement} `,
        };
      },
      async attemptSecureThroughInputMethod({ marker, trigger, replacement }) {
        return {
          application: "OpenBurnBar P29 IBus Probe",
          engine: "openburnbar",
          fieldRole: "password text",
          marker,
          probePID: 2900,
          previousEngine: "xkb:us::eng",
          before: "",
          after: `&&${trigger} `,
          replacementPresent: `&&${trigger} `.includes(replacement),
        };
      },
    },
    async exerciseCancellation() {
      return true;
    },
    async exerciseKillSwitch() {
      return true;
    },
    restored: () => restored,
  };
}

test("P-29 installed runner proves reversible CRUD, engine denial, persistence, and restoration", async () => {
  const value = fixture();
  try {
    const deps = dependencies(value.options);
    const result = await runP29InstalledTextExpansionWorkflow(
      value.options,
      deps,
    );
    assert.equal(result.transcript.operations.expand.after.startsWith("expanded-p29-"), true);
    assert.equal(result.transcript.operations.secureField.replacementPresent, false);
    assert.equal(result.transcript.operations.secureField.fieldRole, "password text");
    assert.equal(result.transcript.persistence.corruptionFailedClosed, true);
    assert.equal(deps.restored(), 1);
    assert.equal(
      fs.existsSync(
        path.join(
          value.options.rawOutputDir,
          "text-expansion-native-transcript.json",
        ),
      ),
      true,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 rejects an RPC-shaped claim that did not replace a real IBus field", async () => {
  const value = fixture();
  try {
    const deps = dependencies(value.options);
    deps.ui.expandThroughInputMethod = async ({ marker, trigger }) => ({
      application: "OpenBurnBar P29 IBus Probe",
      engine: "openburnbar",
      fieldRole: "text",
      marker,
      probePID: 2900,
      previousEngine: "xkb:us::eng",
      before: "",
      after: `&&${trigger} `,
    });
    await assert.rejects(
      () => runP29InstalledTextExpansionWorkflow(value.options, deps),
      /real IBus trigger expansion/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 rejects replacement text committed into the password field", async () => {
  const value = fixture();
  try {
    const deps = dependencies(value.options);
    deps.ui.attemptSecureThroughInputMethod = async ({ marker, replacement }) => ({
      application: "OpenBurnBar P29 IBus Probe",
      engine: "openburnbar",
      fieldRole: "password text",
      marker,
      probePID: 2900,
      previousEngine: "xkb:us::eng",
      before: "",
      after: `${replacement} `,
      replacementPresent: true,
    });
    await assert.rejects(
      () => runP29InstalledTextExpansionWorkflow(value.options, deps),
      /secure field accepted a replacement/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 runner aggregates probe and cleanup failures", async () => {
  const value = fixture();
  try {
    const deps = dependencies(value.options, true);
    deps.rpc.engineStatus = async () => ({
      registration: "missing",
      supportsExternalExpansion: false,
    });
    await assert.rejects(
      () => runP29InstalledTextExpansionWorkflow(value.options, deps),
      (error) => error instanceof AggregateError && error.errors.length === 2,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-29 path validator rejects aliases, nesting, and token symlinks", () => {
  const first = fixture();
  const second = fixture();
  try {
    assert.throws(
      () =>
        validateP29WorkflowPaths({
          ...first.options,
          rawOutputDir: first.options.supportDir,
        }),
      /empty|disjoint/u,
    );
    fs.rmSync(second.options.tokenFile);
    fs.symlinkSync(first.options.tokenFile, second.options.tokenFile);
    assert.throws(() => validateP29WorkflowPaths(second.options), /token/u);
  } finally {
    fs.rmSync(first.root, { recursive: true, force: true });
    fs.rmSync(second.root, { recursive: true, force: true });
  }
});

test("P-29 direct entrypoint owns a real installed adapter and isolated key namespace", async () => {
  for (const marker of [
    'const INSTALLED_DESKTOP = "/usr/bin/openburnbar-linux-desktop"',
    'const INSTALLED_DAEMON = "/usr/libexec/openburnbar-daemon-launch"',
    "OPENBURNBAR_TEXT_EXPANSION_KEY_NAMESPACE",
    'command("secret-tool"',
    'requireCommand("scrot"',
    'const INSTALLED_ENGINE = "/usr/libexec/openburnbar/text-expansion-engine"',
    'requireCommand("ibus", ["engine", "openburnbar"]',
    'requireCommand("ibus", ["engine", originalIBusEngine]',
    'IBUS_FIELD_PROBE',
    'clearAndType(`&&${trigger} `)',
    'focused.role === "password text"',
    'requireCommand("kill", ["-STOP"',
    'OPENBURNBAR_COMPUTER_USE_KILL_SWITCH: "1"',
    "restoreTree(options.supportDir, originalSupport)",
    "restoreTree(options.homeDir, originalHome)",
  ]) assert.ok(PRODUCTION_SOURCE.includes(marker), marker);
  assert.doesNotMatch(PRODUCTION_SOURCE, /fixtureMode\s*:\s*true/u);
  assert.doesNotMatch(PRODUCTION_SOURCE, /engineWrites|writes\s*\+=/u);

  const argv = [
    "--raw-output-dir", "/tmp/raw",
    "--support-dir", "/tmp/support",
    "--home-dir", "/tmp/home",
    "--socket-path", "/tmp/support/daemon.sock",
    "--token-file", "/tmp/support/token",
    "--index-database", "/tmp/support/index.sqlite",
    "--environment", IDENTITY.environmentId,
    "--target-head", IDENTITY.targetHead,
    "--candidate-run-id", IDENTITY.candidateRunId,
    "--candidate-artifact-digest", IDENTITY.candidateArtifactDigest,
    "--package-version", IDENTITY.packageVersion,
    "--manifest-sha256", IDENTITY.manifestSha256,
    "--manifest-signature-sha256", IDENTITY.manifestSignatureSha256,
    "--compositor", "Mutter",
  ];
  let parsed;
  const result = await runP29InstalledProductionWorkflow(argv, {
    createWorkflow(options) {
      parsed = options;
      return { dependencies: { production: true } };
    },
    async runProbe(options, dependencies) {
      return { environmentId: options.environmentId, ...dependencies };
    },
  });
  assert.equal(parsed.socketPath, "/tmp/support/daemon.sock");
  assert.deepEqual(result, {
    environmentId: IDENTITY.environmentId,
    production: true,
  });
});
