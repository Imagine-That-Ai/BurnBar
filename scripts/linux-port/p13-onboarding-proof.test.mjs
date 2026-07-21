import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP13OnboardingProof } from "./capture-p13-onboarding-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P13_PROOF_ROLE,
  validateP13InstalledSession,
  validateP13Proof,
} from "./lib/p13-onboarding-proof.mjs";
import { materializeP13OnboardingSession } from "./materialize-p13-onboarding-session.mjs";
import { readRegularSnapshot } from "./lib/product-proof-closure.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "131313";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p13-fedcba0987654321";
const PROVIDER = "openai";
const SLOT = "p13-ba0987654321";
const LABEL = `P13 ${MARKER}`;

function write(file, bytes, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  if (mode) fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return {
    path: path.relative(root, file).split(path.sep).join("/"),
    sha256: hash(bytes),
    size: bytes.length,
  };
}
function chunk(type, data) {
  const name = Buffer.from(type);
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length);
  name.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}
function png(seed) {
  const width = 320;
  const height = 220;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1)
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed) % 256;
      raw[at + 1] = (y + seed * 2) % 256;
      raw[at + 2] = (x + y + seed * 3) % 256;
    }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
function attestation(root, raw) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicPem = publicKey.export({ type: "spki", format: "pem" });
  write(
    path.join(root, "packaging/linux/openburnbar-linux-ed25519.pub.pem"),
    publicPem,
  );
  const item = (installedPath, bytes, mode) => ({
    path: installedPath,
    type: "file",
    sha256: hash(bytes),
    size: bytes.length,
    mode,
    uid: 0,
    gid: 0,
  });
  const manifest = canonicalJsonBytes(
    createInstalledManifest({
      files: [
        item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"),
        item(
          "/usr/bin/openburnbar-linux-desktop",
          Buffer.from("desktop"),
          "0755",
        ),
        item(
          "/usr/share/openburnbar/attestation/release-ed25519.pub.pem",
          publicPem,
          "0644",
        ),
      ],
      packageVersion: VERSION,
      gitCommit: HEAD,
      packageArchitecture: "aarch64",
      packageFormat: "deb",
      firebaseAppId: "1:2:web:3",
    }),
  );
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return {
    manifestPath: write(path.join(raw, "installed-manifest.json"), manifest),
    signaturePath: write(
      path.join(raw, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function steps(states, attempts = {}) {
  const definitions = [
    ["daemon", "required"],
    ["secret_store", "required"],
    ["provider_paths", "required"],
    ["cloud_identity", "optional"],
    ["portal_input", "optional"],
    ["tray", "optional"],
    ["updates", "optional"],
    ["privacy", "required"],
  ];
  const repairs = {
    cloud_identity: "sign_in",
    portal_input: "grant_portal",
    updates: "open_updates",
  };
  return definitions.map(([id, requirement]) => ({
    id,
    requirement,
    state: states[id] ?? "pending",
    attemptCount:
      attempts[id] ?? (states[id] && states[id] !== "pending" ? 1 : 0),
    detail: states[id] === "blocked" ? `${id} unavailable` : null,
    verifiedAt:
      states[id] && states[id] !== "pending" && states[id] !== "blocked"
        ? "2026-07-20T12:00:00Z"
        : null,
    repairAction: states[id] === "blocked" ? repairs[id] : null,
  }));
}
function snapshot(
  revision,
  currentStepID,
  states,
  completed = false,
  privacyChoices = null,
) {
  return {
    schemaVersion: 1,
    revision,
    currentStepID,
    steps: steps(states),
    privacyChoices,
    completed,
    updatedAt: "2026-07-20T12:00:00Z",
  };
}
function event(phase, at, method, request, result) {
  return { phase, at, method, request, ok: true, error: null, result };
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    ...value.identity,
  };
}
function mutateArtifact(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p13-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-13",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const started = Date.now() - 40_000;
  const at = (offset) => new Date(started + offset).toISOString();
  const verified = {
    daemon: "verified",
    secret_store: "verified",
    provider_paths: "verified",
  };
  const cloudBlockedStates = { ...verified, cloud_identity: "blocked" };
  const cloudSkippedStates = { ...verified, cloud_identity: "skipped" };
  const portalBlockedStates = {
    ...cloudSkippedStates,
    portal_input: "blocked",
  };
  const portalSkippedStates = {
    ...cloudSkippedStates,
    portal_input: "skipped",
  };
  const completeStates = {
    ...portalSkippedStates,
    tray: "skipped",
    updates: "skipped",
    privacy: "verified",
  };
  const complete = snapshot(10, "privacy", completeStates, true, {
    telemetryEnabled: false,
    cloudSyncEnabled: false,
  });
  const configWithSlot = {
    providers: [
      {
        providerID: PROVIDER,
        credentialSlots: [{ slotID: SLOT, label: LABEL }],
      },
    ],
  };
  const configWithoutSlot = {
    providers: [{ providerID: PROVIDER, credentialSlots: [] }],
  };
  const events = [
    event(
      "reset",
      at(1000),
      "daemon.onboarding.reset",
      {},
      snapshot(1, "daemon", {}),
    ),
    {
      phase: "completion-gate-rejected",
      at: at(2000),
      method: "daemon.onboarding.action",
      request: {
        stepID: "privacy",
        action: "save_privacy_choices",
        telemetryEnabled: false,
        cloudSyncEnabled: false,
      },
      ok: false,
      error: "step out of order; daemon is active",
      result: null,
    },
    event(
      "daemon-verified",
      at(3000),
      "daemon.onboarding.action",
      { stepID: "daemon", action: "verify" },
      snapshot(2, "secret_store", { daemon: "verified" }),
    ),
    event(
      "secret-store-verified",
      at(4000),
      "daemon.onboarding.action",
      { stepID: "secret_store", action: "verify" },
      snapshot(3, "provider_paths", {
        daemon: "verified",
        secret_store: "verified",
      }),
    ),
    event(
      "provider-paths-verified",
      at(5000),
      "daemon.onboarding.action",
      { stepID: "provider_paths", action: "verify" },
      snapshot(4, "cloud_identity", verified),
    ),
    event(
      "catalog-read",
      at(6000),
      "daemon.catalog",
      {},
      { catalog: { providers: [{ id: PROVIDER }] } },
    ),
    event(
      "credential-created",
      at(7000),
      "daemon.provider.credential_slot.upsert",
      {
        providerID: PROVIDER,
        slotID: SLOT,
        label: LABEL,
        apiKey: "[REDACTED]",
      },
      { slot: { slotID: SLOT, label: LABEL }, snapshot: configWithSlot },
    ),
    event(
      "credential-readback",
      at(8000),
      "daemon.config.get",
      {},
      configWithSlot,
    ),
    event(
      "credential-removed",
      at(9000),
      "daemon.provider.credential_slot.remove",
      { providerID: PROVIDER, slotID: SLOT },
      { snapshot: configWithoutSlot },
    ),
    event(
      "cloud-unavailable",
      at(10_000),
      "daemon.onboarding.action",
      { stepID: "cloud_identity", action: "verify" },
      snapshot(5, "cloud_identity", cloudBlockedStates),
    ),
    event(
      "cloud-skipped",
      at(11_000),
      "daemon.onboarding.snapshot",
      {},
      snapshot(6, "portal_input", cloudSkippedStates),
    ),
    event(
      "portal-unavailable",
      at(12_000),
      "daemon.onboarding.snapshot",
      {},
      snapshot(7, "portal_input", portalBlockedStates),
    ),
    event(
      "portal-skipped",
      at(13_000),
      "daemon.onboarding.snapshot",
      {},
      snapshot(8, "tray", portalSkippedStates),
    ),
    event(
      "tray-skipped",
      at(14_000),
      "daemon.onboarding.action",
      { stepID: "tray", action: "skip" },
      snapshot(9, "updates", { ...portalSkippedStates, tray: "skipped" }),
    ),
    event(
      "updates-unavailable",
      at(15_000),
      "daemon.onboarding.action",
      { stepID: "updates", action: "verify" },
      snapshot(10, "updates", {
        ...portalSkippedStates,
        tray: "skipped",
        updates: "blocked",
      }),
    ),
    event(
      "updates-skipped",
      at(16_000),
      "daemon.onboarding.action",
      { stepID: "updates", action: "skip" },
      snapshot(11, "privacy", {
        ...portalSkippedStates,
        tray: "skipped",
        updates: "skipped",
      }),
    ),
    event(
      "privacy-saved",
      at(17_000),
      "daemon.onboarding.action",
      {
        stepID: "privacy",
        action: "save_privacy_choices",
        telemetryEnabled: false,
        cloudSyncEnabled: false,
      },
      complete,
    ),
    event(
      "restart-snapshot",
      at(18_000),
      "daemon.onboarding.snapshot",
      {},
      complete,
    ),
    event(
      "privacy-config-readback",
      at(19_000),
      "daemon.config.get",
      {},
      {
        ...configWithoutSlot,
        telemetryEnabled: false,
        cloudSyncEnabled: false,
      },
    ),
  ];
  json(path.join(raw, "onboarding-marker.json"), {
    marker: MARKER,
    providerID: PROVIDER,
    slotID: SLOT,
    credentialLabel: LABEL,
    safety: {
      credentialMaterialRecordedInEvidence: false,
      credentialRemoved: true,
      productionOAuthClaimed: false,
    },
  });
  json(path.join(raw, "onboarding-daemon-transcript.json"), {
    producer: "openburnbar-p13-installed-onboarding-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events,
  });
  const uiEvent = (phase, offset, observed, pid) => ({
    phase,
    at: at(offset),
    appPid: pid,
    marker: MARKER,
    manifestSha256: identity.manifestSha256,
    observed,
  });
  const action = (phase, offset, name) => ({
    phase,
    at: at(offset),
    result: {
      producer: "openburnbar-p13-atspi-control-v1",
      activation: { name, role: "push button", action: "click" },
    },
  });
  json(path.join(raw, "onboarding-ui-transcript.json"), {
    producer: "openburnbar-p13-installed-onboarding-ui-probe-v1",
    productionAuth: {
      configured: false,
      retryOutcome: "remained-unavailable",
      cancelOutcome: "not-started-unavailable",
      productionSuccessClaimed: false,
    },
    events: [
      uiEvent(
        "provider-setup",
        4500,
        {
          catalogVisible: true,
          credentialFieldVisible: true,
          secureStorageCopyVisible: true,
        },
        1301,
      ),
      uiEvent(
        "cloud-blocked",
        10_200,
        { blockedVisible: true, retryVisible: true, skipVisible: true },
        1302,
      ),
      uiEvent(
        "portal-blocked",
        12_200,
        { blockedVisible: true, retryVisible: true, skipVisible: true },
        1302,
      ),
      uiEvent(
        "privacy",
        16_500,
        { choicesVisible: true, saveVisible: true },
        1303,
      ),
      uiEvent(
        "completed",
        18_500,
        { completedVisible: true, resetVisible: true },
        1304,
      ),
    ],
    actions: [
      action("cloud-retry", 10_400, "Retry check"),
      action("cloud-skip", 10_700, "Skip for now"),
      action("portal-retry", 11_700, "Check integration"),
      action("portal-skip", 12_500, "Skip for now"),
    ],
  });
  for (const [index, name] of [
    "onboarding-provider.png",
    "onboarding-cloud.png",
    "onboarding-privacy.png",
    "onboarding-completed.png",
  ].entries())
    write(path.join(raw, name), png(index + 1));
  const result = materializeP13OnboardingSession(
    {
      repoRoot: root,
      outputRoot: input,
      rawEvidenceDir: raw,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      packageVersion: VERSION,
      compositor: "GNOME Shell",
      ...identity,
    },
    {
      installedVerifier() {},
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return {
    root,
    raw,
    input,
    identity,
    session: result.document,
    sessionFile: result.output,
  };
}

test("P-13 materializer and capture derive a candidate-bound installed onboarding proof", () => {
  const value = fixture();
  const result = captureP13OnboardingProof(
    {
      ...binding(value),
      inputRoot: value.input,
      sessionReport: value.sessionFile,
    },
    { resolveHead: () => HEAD, now: () => new Date(Date.now() + 60_000) },
  );
  assert.equal(result.document.claim.passed, true);
  assert.equal(result.document.claim.productionOAuthSuccess, false);
  assert.equal(
    JSON.parse(fs.readFileSync(result.registration)).artifacts[0].role,
    P13_PROOF_ROLE,
  );
  assert.doesNotThrow(() =>
    validateP13Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, result.output),
        "proof",
      ),
    }),
  );
});

test("P-13 rejects forged completion, retained credentials, OAuth overclaims, and replayed screenshots", () => {
  for (const mutate of [
    (value) =>
      mutateArtifact(
        value,
        value.session.evidence.daemonTranscript,
        (payload) => {
          payload.events.find(
            (row) => row.phase === "restart-snapshot",
          ).result.completed = false;
        },
      ),
    (value) =>
      mutateArtifact(
        value,
        value.session.evidence.daemonTranscript,
        (payload) => {
          payload.events
            .find((row) => row.phase === "credential-removed")
            .result.snapshot.providers[0].credentialSlots.push({
              slotID: SLOT,
              label: LABEL,
            });
        },
      ),
    (value) =>
      mutateArtifact(value, value.session.evidence.uiTranscript, (payload) => {
        payload.productionAuth.productionSuccessClaimed = true;
      }),
    (value) =>
      mutateArtifact(value, value.session.evidence.uiTranscript, (payload) => {
        payload.actions.find(
          (row) => row.phase === "portal-skip",
        ).result.activation.name = "Continue later";
      }),
    (value) => {
      const source = path.join(
        value.root,
        value.session.evidence.providerScreenshot.path,
      );
      const target = path.join(
        value.root,
        value.session.evidence.cloudScreenshot.path,
      );
      fs.copyFileSync(source, target);
      Object.assign(
        value.session.evidence.cloudScreenshot,
        record(value.root, target),
      );
    },
  ]) {
    const value = fixture();
    mutate(value);
    assert.throws(() =>
      validateP13InstalledSession(value.session, binding(value), {
        repoRoot: value.root,
      }),
    );
  }
});
