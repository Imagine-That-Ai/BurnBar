import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  P24_CONFIG_WRITES,
  P24_SETTINGS_TAB_OWNERSHIP,
  P24_SETTINGS_TABS,
  buildP24Proof,
  validateP24InstalledSession,
  validateP24Proof,
} from "./lib/p24-settings-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import { readRegularSnapshot } from "./lib/product-proof-closure.mjs";

const HEAD = "4".repeat(40);
const RUN_ID = "242424";
const DIGEST = `sha256:${"5".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";

function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
  return file;
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
  const width = 400;
  const height = 240;
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1)
    for (let x = 0; x < width; x += 1) {
      const offset = y * (width * 3 + 1) + 1 + x * 3;
      raw[offset] = (x + seed * 7) % 256;
      raw[offset + 1] = (y + seed * 11) % 256;
      raw[offset + 2] = (x + y + seed * 13) % 256;
    }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
function attestation(root, evidenceRoot) {
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
  const manifestFile = write(
    path.join(evidenceRoot, "raw/installed-manifest.json"),
    manifest,
  );
  const signatureFile = write(
    path.join(evidenceRoot, "raw/installed-manifest.json.sig"),
    signature,
  );
  return {
    manifest: record(root, manifestFile),
    signature: record(root, signatureFile),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function nodes(title, extra = []) {
  return [
    { name: "Search settings", states: ["focusable"], actions: ["focus"] },
    { name: title, states: ["focusable", "focused"], actions: ["click"] },
    ...extra.map((name) => ({ name, states: [], actions: [] })),
    ...Array.from({ length: 8 }, (_, index) => ({
      name: `node-${index}`,
      states: [],
      actions: [],
    })),
  ];
}
function binding(value) {
  return {
    repoRoot: value.root,
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    manifestSha256: value.identity.manifestSha256,
    manifestSignatureSha256: value.identity.manifestSignatureSha256,
  };
}
function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "openburnbar-p24-proof-"));
  const evidenceRoot = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-24",
    ENVIRONMENT,
  );
  fs.mkdirSync(path.join(evidenceRoot, "raw"), { recursive: true });
  const identity = attestation(root, evidenceRoot);
  const start = Date.now() - 30_000;
  const at = (offset) => new Date(start + offset).toISOString();
  const tabs = P24_SETTINGS_TABS.map(([tabId, title], index) => {
    const shot = write(
      path.join(evidenceRoot, "raw", `settings-${tabId}.png`),
      png(index + 1),
    );
    return {
      tabId,
      query: title,
      deepLink: "openburnbar://settings",
      selectedName: title,
      focusedName: title,
      action: "click",
      nodes: nodes(title),
      screenshot: record(root, shot),
      at: at(index * 500),
    };
  });
  const writes = P24_CONFIG_WRITES.map(({ field, control }) => ({
    kind: "daemon-config",
    tabId: "data-privacy",
    control,
    field,
    method: "daemon.config.update",
    before: { field, value: false },
    requested: { field, value: true },
    readback: { field, value: true },
    afterRestart: { field, value: true },
    restored: { field, value: false },
    status: "passed",
  }));
  const launchBefore = {
    enabled: false,
    path: "/home/test/.config/autostart/openburnbar.desktop",
    source: "packaged",
    userOverride: false,
  };
  const launchChanged = {
    enabled: true,
    path: "/home/test/.config/autostart/openburnbar.desktop",
    source: "user",
    userOverride: true,
  };
  writes.push({
    kind: "native",
    tabId: "general",
    control: "Launch OpenBurnBar at login",
    field: "launchAtLogin",
    method: "launch_at_login_set",
    before: launchBefore,
    requested: launchChanged,
    readback: launchChanged,
    afterRestart: launchChanged,
    restored: launchBefore,
    status: "passed",
  });
  const degradedShot = write(
    path.join(evidenceRoot, "raw/settings-degraded.png"),
    png(91),
  );
  const recoveredShot = write(
    path.join(evidenceRoot, "raw/settings-recovered.png"),
    png(92),
  );
  const recovery = {
    restartCount: 6,
    degraded: {
      state: "degraded",
      at: at(9000),
      focusedName: "Retry",
      nodes: nodes("Retry", ["Settings config did not respond"]),
      screenshot: record(root, degradedShot),
    },
    recovered: {
      state: "recovered",
      at: at(10000),
      focusedName: "Settings healthy",
      nodes: nodes("Settings healthy", ["Connected"]),
      screenshot: record(root, recoveredShot),
    },
  };
  const transcriptPayload = {
    schemaVersion: 2,
    producer: "openburnbar-p24-installed-settings-probes-v2",
    marker: "p24-fedcba0987654321",
    fixtureMode: false,
    tabs: tabs.map((tab) => ({
      ...tab,
      screenshot: path.basename(tab.screenshot.path),
    })),
    tabOwnership: P24_SETTINGS_TAB_OWNERSHIP,
    writeReceipts: writes,
    recovery: {
      ...recovery,
      degraded: { ...recovery.degraded, screenshot: "settings-degraded.png" },
      recovered: {
        ...recovery.recovered,
        screenshot: "settings-recovered.png",
      },
    },
    originalStateRestored: true,
  };
  const transcriptFile = write(
    path.join(evidenceRoot, "raw/settings-native-transcript.json"),
    `${JSON.stringify(transcriptPayload, null, 2)}\n`,
  );
  const session = {
    schemaVersion: 2,
    id: "openburnbar-linux-p24-installed-settings-session-v2",
    requirementId: "P-24",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    package: {
      architecture: "aarch64",
      format: "deb",
      installed: true,
      manifest: identity.manifest,
      signature: identity.signature,
      source: "verified-live-installed-candidate",
      version: VERSION,
    },
    desktop: {
      compositor: "Mutter",
      desktop: "GNOME",
      displayServer: "X11",
      liveSession: true,
    },
    capture: {
      startedAt: at(0),
      endedAt: at(10000),
      fixtureMode: false,
      method: "installed-live-product-session",
    },
    marker: "p24-fedcba0987654321",
    settings: {
      deepLink: "openburnbar://settings",
      tabs,
      tabOwnership: P24_SETTINGS_TAB_OWNERSHIP,
      writeReceipts: writes,
    },
    recovery,
    evidence: { nativeTranscript: record(root, transcriptFile) },
  };
  const sessionFile = write(
    path.join(evidenceRoot, "p24-installed-settings-session.json"),
    `${JSON.stringify(session, null, 2)}\n`,
  );
  return { root, evidenceRoot, identity, session, sessionFile };
}
function mutateSession(value, change) {
  const session = structuredClone(value.session);
  change(session);
  return session;
}

test("P-24 validates and builds exact installed Settings proof", (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const validated = validateP24InstalledSession(value.session, binding(value), {
    repoRoot: value.root,
  });
  const source = record(value.root, value.sessionFile);
  const collectedAt = new Date(
    Date.parse(value.session.capture.endedAt) + 1000,
  ).toISOString();
  const proof = buildP24Proof({
    session: validated.document,
    source,
    collectedAt,
  });
  const proofFile = write(
    path.join(
      value.evidenceRoot,
      "feature-artifacts/p24-installed-settings-proof.json",
    ),
    `${JSON.stringify(proof, null, 2)}\n`,
  );
  const result = validateP24Proof(
    {
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        record(value.root, proofFile).path,
        "P-24 proof",
      ),
    },
    Date.parse(collectedAt) + 1000,
  );
  assert.equal(result.claim.searchableTabs, 16);
  assert.equal(result.claim.verifiedWrites, 4);
  assert.equal(result.claim.delegatedOrReadOnlyTabs, 14);
  assert.equal(result.evidence.length, 19);
});

test("P-24 rejects missing tabs, forged readback, screenshot reuse, and restart loss", (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  for (const [label, change, pattern] of [
    [
      "missing tab",
      (session) => session.settings.tabs.pop(),
      /16 navigable tabs/u,
    ],
    [
      "forged readback",
      (session) => {
        session.settings.writeReceipts[3].readback = {
          ...session.settings.writeReceipts[3].readback,
          enabled: false,
        };
      },
      /round-trip/u,
    ],
    [
      "screenshot reuse",
      (session) => {
        session.settings.tabs[1].screenshot =
          session.settings.tabs[0].screenshot;
      },
      /screenshots must be visually distinct/u,
    ],
    [
      "restart loss",
      (session) => {
        session.settings.writeReceipts[1].afterRestart =
          session.settings.writeReceipts[1].before;
      },
      /round-trip/u,
    ],
    [
      "ownership overclaim",
      (session) => {
        session.settings.tabOwnership[2].mode = "owned-write";
      },
      /ownership/u,
    ],
  ]) {
    assert.throws(
      () =>
        validateP24InstalledSession(
          mutateSession(value, change),
          binding(value),
          { repoRoot: value.root },
        ),
      pattern,
      label,
    );
  }
});

test("P-24 rejects candidate substitution and stale collection", (t) => {
  const value = fixture();
  t.after(() => fs.rmSync(value.root, { recursive: true, force: true }));
  const source = record(value.root, value.sessionFile);
  const proof = buildP24Proof({
    session: value.session,
    source,
    collectedAt: new Date(
      Date.parse(value.session.capture.endedAt) + 1000,
    ).toISOString(),
  });
  const proofFile = write(
    path.join(
      value.evidenceRoot,
      "feature-artifacts/p24-installed-settings-proof.json",
    ),
    `${JSON.stringify(proof, null, 2)}\n`,
  );
  const snapshot = readRegularSnapshot(
    value.root,
    record(value.root, proofFile).path,
    "P-24 proof",
  );
  assert.throws(
    () =>
      validateP24Proof({ ...binding(value), candidateRunId: "999", snapshot }),
    /selected installed candidate/u,
  );
  assert.throws(
    () =>
      validateP24Proof(
        { ...binding(value), snapshot },
        Date.parse(proof.collectedAt) + 16 * 60 * 1000,
      ),
    /stale/u,
  );
});
