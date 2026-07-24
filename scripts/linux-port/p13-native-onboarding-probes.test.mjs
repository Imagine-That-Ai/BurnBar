import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  parseP13Arguments,
  runP13NativeOnboardingProbes,
} from "./run-p13-native-onboarding-probes.mjs";

const FLAGS = [
  "--raw-output-dir",
  "/tmp/raw",
  "--support-dir",
  "/tmp/support",
  "--home-dir",
  "/tmp/home",
  "--socket-path",
  "/tmp/support/socket",
  "--token-file",
  "/tmp/support/token",
  "--index-database",
  "/tmp/support/index.sqlite",
  "--environment",
  "ubuntu-24.04-gnome-x11-aarch64",
  "--target-head",
  "1".repeat(40),
  "--candidate-run-id",
  "1313",
  "--candidate-artifact-digest",
  `sha256:${"2".repeat(64)}`,
  "--package-version",
  "1.2.3",
  "--manifest-sha256",
  "3".repeat(64),
  "--manifest-signature-sha256",
  "4".repeat(64),
  "--compositor",
  "GNOME Shell",
];

test("P-13 CLI requires every candidate and isolated-daemon binding", () => {
  const parsed = parseP13Arguments(FLAGS);
  assert.equal(parsed.environmentId, "ubuntu-24.04-gnome-x11-aarch64");
  assert.equal(parsed.socketPath, "/tmp/support/socket");
  assert.throws(
    () => parseP13Arguments(FLAGS.slice(0, -2)),
    /--compositor is required/u,
  );
  assert.throws(
    () => parseP13Arguments([...FLAGS, "--unknown", "x"]),
    /invalid argument/u,
  );
});

test("P-13 default lane is Linux-only before installed verification", async () => {
  let verified = false;
  await assert.rejects(
    runP13NativeOnboardingProbes(
      {},
      {
        platform: "darwin",
        installedVerifier() {
          verified = true;
        },
      },
    ),
    /must execute on Linux/u,
  );
  assert.equal(verified, false);
});

function onboardingSnapshot(currentStepID, completed = false) {
  const ids = [
    "daemon",
    "secret_store",
    "provider_paths",
    "cloud_identity",
    "portal_input",
    "tray",
    "updates",
    "privacy",
  ];
  return {
    schemaVersion: 1,
    revision: completed ? 9 : 1,
    currentStepID,
    steps: ids.map((id) => ({
      id,
      state:
        id === "portal_input" && currentStepID === "portal_input"
          ? "blocked"
          : "pending",
    })),
    privacyChoices: completed
      ? { telemetryEnabled: false, cloudSyncEnabled: false }
      : null,
    completed,
    updatedAt: "2026-07-20T12:00:00Z",
  };
}

test("P-13 orchestrator binds daemon RPC, UI recovery, restart, and secret cleanup", async () => {
  const base = path.join(process.cwd(), ".tmp/p13-native-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  const support = path.join(root, "support");
  const home = path.join(root, "home");
  for (const directory of [raw, support, home])
    fs.mkdirSync(directory, { mode: 0o700 });
  const token = path.join(support, "token");
  fs.writeFileSync(token, crypto.randomBytes(32).toString("hex"), {
    mode: 0o600,
  });
  const complete = onboardingSnapshot("privacy", true);
  const responses = [
    onboardingSnapshot("daemon"),
    new Error("step out of order while daemon is active"),
    onboardingSnapshot("secret_store"),
    onboardingSnapshot("provider_paths"),
    onboardingSnapshot("cloud_identity"),
    { catalog: { providers: [{ id: "openai" }] } },
    { slot: { slotID: "p13-ba0987654321" } },
    {
      providers: [
        {
          providerID: "openai",
          credentialSlots: [{ slotID: "p13-ba0987654321" }],
        },
      ],
    },
    {
      snapshot: { providers: [{ providerID: "openai", credentialSlots: [] }] },
    },
    {
      ...onboardingSnapshot("cloud_identity"),
      steps: onboardingSnapshot("cloud_identity").steps.map((row) =>
        row.id === "cloud_identity" ? { ...row, state: "blocked" } : row,
      ),
    },
    onboardingSnapshot("portal_input"),
    onboardingSnapshot("portal_input"),
    onboardingSnapshot("tray"),
    onboardingSnapshot("updates"),
    onboardingSnapshot("updates"),
    onboardingSnapshot("privacy"),
    complete,
    complete,
    { telemetryEnabled: false, cloudSyncEnabled: false },
  ];
  const methods = [];
  const ui = {
    pid: 2000,
    async launch() {
      return { pid: this.pid++ };
    },
    snapshot(label) {
      const rows = {
        "provider-setup": [
          "Connect a provider",
          "Provider",
          "API key",
          "Credential label",
          "native Secret Service",
          "Store credential securely",
        ],
        "cloud-blocked": [
          "Blocked",
          "native cloud sign-in",
          "Retry check",
          "Skip for now",
        ],
        "portal-blocked": [
          "Blocked",
          "Desktop portal",
          "Retry check",
          "Skip for now",
        ],
        privacy: ["Privacy choices", "Telemetry", "Cloud sync", "Save choices"],
        completed: ["Setup complete", "Reset setup"],
      }[label];
      return { nodes: rows.map((name) => ({ name })) };
    },
    screenshot(name) {
      fs.writeFileSync(path.join(raw, name), Buffer.alloc(2048, 7));
    },
    async activate(name) {
      return {
        producer: "openburnbar-p13-atspi-control-v1",
        activation: { name, role: "push button", action: "click" },
      };
    },
    async stop() {},
  };
  let restarts = 0;
  let restores = 0;
  try {
    const result = await runP13NativeOnboardingProbes(
      {
        rawOutputDir: raw,
        supportDir: support,
        homeDir: home,
        socketPath: path.join(support, "socket"),
        tokenFile: token,
        indexDatabase: path.join(support, "index.sqlite"),
        environmentId: "ubuntu-24.04-gnome-x11-aarch64",
        targetHead: "1".repeat(40),
        candidateRunId: "1313",
        candidateArtifactDigest: `sha256:${"2".repeat(64)}`,
        packageVersion: "1.2.3",
        manifestSha256: "3".repeat(64),
        manifestSignatureSha256: "4".repeat(64),
        compositor: "GNOME Shell",
      },
      {
        platform: "linux",
        desktopSession: true,
        installedVerifier() {},
        desktopProcessIDs: () => [],
        marker: "p13-fedcba0987654321",
        runner: {},
        daemon: {
          async prepare() {},
          async restart() {
            restarts += 1;
          },
          async restore() {
            restores += 1;
          },
        },
        async rpc(method) {
          methods.push(method);
          const response = responses.shift();
          if (response instanceof Error) throw response;
          return structuredClone(response);
        },
        ui,
      },
    );
    assert.equal(result.providerID, "openai");
    assert.equal(responses.length, 0);
    assert.equal(restarts, 1);
    assert.equal(restores, 1);
    assert.ok(methods.includes("daemon.provider.credential_slot.remove"));
    assert.ok(
      fs.existsSync(path.join(raw, "onboarding-daemon-transcript.json")),
    );
    const transcript = fs.readFileSync(
      path.join(raw, "onboarding-daemon-transcript.json"),
      "utf8",
    );
    assert.equal(transcript.includes("p13-temporary-"), false);
    assert.equal(transcript.includes('"apiKey": "[REDACTED]"'), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
