import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP23ProviderWorkspaceProof } from "./capture-p23-provider-workspace-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP23InstalledSession,
  validateP23Proof,
} from "./lib/p23-provider-workspace-proof.mjs";
import { materializeP23ProviderWorkspaceSession } from "./materialize-p23-provider-workspace-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-23.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "232323";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p23-fedcba0987654321";
const PROVIDER = "codex";
const MODEL = "gpt-5";
const CUSTOM = "gpt-5-p23-87654321";
const ALIAS = "p23-alias-87654321";
const VARIANT = "p23-variant-87654321";

function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
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
  const width = 480;
  const height = 300;
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
      raw[at + 1] = (y * 2 + seed) % 256;
      raw[at + 2] = (x + y + seed) % 256;
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
function config(
  statusA = "ready",
  statusB = "ready",
  preferred = "slot-a",
  lifecycle = false,
) {
  const updatedAt =
    (Date.parse("2026-07-20T15:00:00.000Z") - Date.UTC(2001, 0, 1)) / 1000;
  return {
    routerMode: "same_model_failover",
    telemetryEnabled: false,
    privacyOptIn: false,
    cloudSyncEnabled: false,
    providers: [
      {
        providerID: PROVIDER,
        isEnabled: true,
        preferredCredentialSlotID: preferred,
        credentialSlots: [
          {
            slotID: "slot-a",
            label: "Primary",
            isEnabled: true,
            status: statusA,
            updatedAt,
            ...(statusA === "exhausted"
              ? { lastQuotaRemainingPercent: 0 }
              : {}),
          },
          {
            slotID: "slot-b",
            label: "Backup",
            isEnabled: true,
            status: statusB,
            updatedAt,
          },
        ],
        modelVariants: lifecycle
          ? [
              {
                variantID: VARIANT,
                baseModelID: MODEL,
                displayName: "Proof high",
                thinkingLevel: "high",
              },
            ]
          : [],
        modelAliases: lifecycle
          ? [{ aliasID: ALIAS, baseModelID: MODEL, displayName: "Proof alias" }]
          : [],
        modelDisplayOverrides: [],
        customModels: lifecycle
          ? [{ modelID: CUSTOM, displayName: "Proof custom" }]
          : [],
        preferredModelIDs: [MODEL],
        disabledAdvertisedModelIDs: [],
        ollamaEndpoints: [],
        baseURL: "https://api.example.test",
      },
    ],
  };
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
function mutate(value, descriptor, change) {
  const file = path.join(value.root, descriptor.path);
  const payload = JSON.parse(fs.readFileSync(file));
  change(payload);
  json(file, payload);
  Object.assign(descriptor, record(value.root, file));
}

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p23-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "proof-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-23",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const start = Date.now() - 60_000;
  const at = (offset) => new Date(start + offset).toISOString();
  const nativeAt = (offset) => (start + offset - Date.UTC(2001, 0, 1)) / 1000;
  const original = config();
  const lifecycle = config("ready", "ready", "slot-b", true);
  const drain = config("exhausted", "ready", "slot-a", true);
  const marker = {
    marker: MARKER,
    providerID: PROVIDER,
    providerLabel: "Codex",
    baseModelID: MODEL,
    customModelID: CUSTOM,
    aliasID: ALIAS,
    variantID: VARIANT,
    slotA: { slotID: "slot-a", label: "Primary" },
    slotB: { slotID: "slot-b", label: "Backup" },
    liveRouteEvidence: {
      manualA: "route-a",
      manualB: "route-b",
      automaticDrain: "route-drain",
    },
    safety: {
      controlledQuotaStateMutation: true,
      credentialsRecorded: false,
      originalConfigRestored: true,
      unsupportedLiveFailoverClaimed: false,
    },
  };
  json(path.join(raw, "provider-marker.json"), marker);
  const events = [];
  const push = (phase, method, request, result, offset) =>
    events.push({
      phase,
      at: at(offset),
      method,
      request,
      ok: true,
      error: null,
      result,
    });
  push(
    "config-original",
    "daemon.config.get",
    {},
    { snapshot: original },
    1000,
  );
  push(
    "catalog-original",
    "daemon.catalog",
    {},
    {
      catalog: {
        providers: [
          {
            id: PROVIDER,
            displayName: "Codex",
            models: [{ id: MODEL, displayName: "GPT-5" }],
          },
        ],
      },
    },
    2000,
  );
  push(
    "quota-original",
    "daemon.quota.signals.recent",
    { limit: 200 },
    { signals: [], snapshots: [] },
    3000,
  );
  push(
    "route-log-baseline",
    "daemon.proxy.route_log.recent",
    { limit: 200 },
    { entries: [] },
    4000,
  );
  const clientID = `p23-proof-${MARKER}`;
  const sessionID = `p23-session-${MARKER}`;
  const runRequest = {
    clientID,
    sessionID,
    modelID: MODEL,
    prompt: `Reply with exactly P23_OK_${MARKER}. Do not call tools.`,
  };
  const mutationDate = nativeAt(12500);
  push(
    "client-attach",
    "client.attach",
    { clientID, sessionID },
    { attached: true },
    5000,
  );
  push(
    "client-claim",
    "client.claimControl",
    { clientID },
    { claimed: true },
    6000,
  );
  push(
    "manual-a-config",
    "daemon.config.update",
    { snapshot: config() },
    { snapshot: config() },
    7000,
  );
  push("manual-a-run", "run.create", runRequest, { runID: "run-a" }, 8000);
  push(
    "manual-a-route",
    "daemon.proxy.route_log.recent",
    { limit: 200 },
    {
      id: "route-a",
      occurredAt: nativeAt(8500),
      providerID: PROVIDER,
      accountID: "slot-a",
      clientModelSlug: MODEL,
      finalStatus: "exact",
      httpStatus: 200,
    },
    9000,
  );
  push(
    "manual-b-config",
    "daemon.config.update",
    { snapshot: config("ready", "ready", "slot-b") },
    { snapshot: config("ready", "ready", "slot-b") },
    10000,
  );
  push("manual-b-run", "run.create", runRequest, { runID: "run-b" }, 11000);
  push(
    "manual-b-route",
    "daemon.proxy.route_log.recent",
    { limit: 200 },
    {
      id: "route-b",
      occurredAt: nativeAt(11500),
      providerID: PROVIDER,
      accountID: "slot-b",
      clientModelSlug: MODEL,
      finalStatus: "exact",
      httpStatus: 200,
    },
    12000,
  );
  push(
    "custom-upsert",
    "daemon.provider.custom_model.upsert",
    {
      providerID: PROVIDER,
      customModel: {
        modelID: CUSTOM,
        displayName: "Proof custom",
        createdAt: mutationDate,
        updatedAt: mutationDate,
      },
    },
    { snapshot: config("ready", "ready", "slot-b", true) },
    13000,
  );
  push(
    "alias-upsert",
    "daemon.provider.model_alias.upsert",
    {
      providerID: PROVIDER,
      alias: {
        aliasID: ALIAS,
        baseModelID: MODEL,
        displayName: "Proof alias",
        createdAt: mutationDate,
        updatedAt: mutationDate,
      },
    },
    { snapshot: config("ready", "ready", "slot-b", true) },
    14000,
  );
  push(
    "variant-upsert",
    "daemon.provider.model_variant.upsert",
    {
      providerID: PROVIDER,
      variant: {
        variantID: VARIANT,
        baseModelID: MODEL,
        displayName: "Proof high",
        thinkingLevel: "high",
        createdAt: mutationDate,
        updatedAt: mutationDate,
      },
    },
    { snapshot: lifecycle },
    15000,
  );
  push(
    "automatic-drain-config",
    "daemon.config.update",
    { snapshot: drain },
    { snapshot: drain },
    16000,
  );
  push(
    "automatic-drain-run",
    "run.create",
    runRequest,
    { runID: "run-drain" },
    17000,
  );
  push(
    "automatic-drain-route",
    "daemon.proxy.route_log.recent",
    { limit: 200 },
    {
      id: "route-drain",
      occurredAt: nativeAt(17500),
      providerID: PROVIDER,
      accountID: "slot-b",
      clientModelSlug: MODEL,
      finalStatus: "same_model_failover",
      httpStatus: 200,
    },
    18000,
  );
  push("restart-config", "daemon.config.get", {}, { snapshot: drain }, 19000);
  push(
    "degraded-config",
    "daemon.config.update",
    { snapshot: config("coolingDown", "coolingDown", "slot-a", true) },
    { snapshot: config("coolingDown", "coolingDown", "slot-a", true) },
    20000,
  );
  push(
    "unavailable-config",
    "daemon.config.update",
    { snapshot: config("missingSecret", "missingSecret", "slot-a", true) },
    { snapshot: config("missingSecret", "missingSecret", "slot-a", true) },
    21000,
  );
  push(
    "restore-config",
    "daemon.config.update",
    { snapshot: original },
    { snapshot: original },
    22000,
  );
  push(
    "restore-restart-config",
    "daemon.config.get",
    {},
    { snapshot: original },
    23000,
  );
  json(path.join(raw, "provider-daemon-transcript.json"), {
    producer: "openburnbar-p23-installed-provider-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    startedAt: at(0),
    events,
  });
  const observed = [
    {
      workspace: true,
      provider: true,
      health: true,
      failover: true,
      account: true,
      exhausted: true,
    },
    { custom: true, alias: true, variant: true, focused: true },
    { provider: true, alias: true, focused: true },
    { degraded: true, unavailableFailover: true, cooling: true },
    { unavailable: true, missing: true, routeUnavailable: true },
  ];
  json(path.join(raw, "provider-ui-transcript.json"), {
    producer: "openburnbar-p23-installed-provider-ui-probe-v1",
    events: [
      "detail",
      "model-deep-link",
      "deep-link-restoration",
      "degraded",
      "unavailable",
    ].map((phase, index) => ({
      phase,
      at: at(24000 + index * 1000),
      appPid: 2300 + index,
      marker: MARKER,
      manifestSha256: identity.manifestSha256,
      observed: observed[index],
    })),
  });
  [
    "provider-detail.png",
    "provider-model-deep-link.png",
    "provider-deep-link-restored.png",
    "provider-degraded.png",
    "provider-unavailable.png",
  ].forEach((name, index) => write(path.join(raw, name), png(index + 1)));
  const materialized = materializeP23ProviderWorkspaceSession(
    {
      ...binding({ root, identity }),
      outputRoot: input,
      rawEvidenceDir: raw,
      compositor: "Mutter",
    },
    {
      installedVerifier: () => ({}),
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return {
    root,
    raw,
    input,
    identity,
    session: materialized.document,
    sessionPath: materialized.output,
  };
}

function context(value, proofFile) {
  const subjects = path.join(value.input, "release-subjects");
  const aggregate = record(
    value.root,
    json(path.join(subjects, "aggregate.json"), { passed: true }),
  );
  const runtime = record(
    value.root,
    json(path.join(subjects, "runtime.json"), {
      daemonVersion: VERSION,
      shellVersion: VERSION,
    }),
  );
  const environment = record(
    value.root,
    json(path.join(subjects, "environment.json"), {
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      architecture: "aarch64",
      passed: true,
    }),
  );
  const pkg = record(
    value.root,
    write(path.join(subjects, "package.deb"), "package\n"),
  );
  const proof = record(value.root, proofFile);
  return {
    schemaVersion: 1,
    repoRoot: value.root,
    requirementId: "P-23",
    checkId: "p-23.provider-and-model-workspace",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-23",
        environmentId: ENVIRONMENT,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.session.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: "feature.provider-workspace-installed", ...proof },
        ],
      },
    },
    subjects: {
      release: aggregate,
      packageManifest: value.session.package.manifest,
      packages: [pkg],
      runtimes: [runtime],
      installation: [aggregate],
      environment,
      features: [],
    },
  };
}

test("P-23 materializes, captures, and validates installed provider workspace evidence", async () => {
  const value = fixture();
  try {
    const validated = validateP23InstalledSession(
      value.session,
      binding(value),
    );
    assert.equal(validated.daemonEvents, 23);
    assert.equal(validated.liveCredentialRoutes, 3);
    assert.equal(validated.lifecycleMutations, 3);
    const captured = captureP23ProviderWorkspaceProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionPath,
      },
      { resolveHead: () => HEAD, now: () => new Date(Date.now() + 60_000) },
    );
    const proof = validateP23Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        path.relative(value.root, captured.output),
        "P-23 proof",
      ),
    });
    assert.equal(proof.proof.claim.originalConfigRestored, true);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-23 rejects a transcript that contains credential material", () => {
  const value = fixture();
  try {
    mutate(value, value.session.evidence.daemonTranscript, (payload) => {
      payload.events[0].result.apiKey = "must-not-be-recorded";
    });
    assert.throws(
      () => validateP23InstalledSession(value.session, binding(value)),
      /contains credentials/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-23 rejects route substitution and failed config restoration", () => {
  const route = fixture();
  const restore = fixture();
  try {
    mutate(route, route.session.evidence.daemonTranscript, (payload) => {
      payload.events[17].result.accountID = "slot-a";
    });
    assert.throws(
      () => validateP23InstalledSession(route.session, binding(route)),
      /native successful credential route/u,
    );
    mutate(restore, restore.session.evidence.daemonTranscript, (payload) => {
      payload.events[22].result.snapshot.routerMode = "exact_only";
    });
    assert.throws(
      () => validateP23InstalledSession(restore.session, binding(restore)),
      /not restored/u,
    );
  } finally {
    fs.rmSync(route.root, { recursive: true, force: true });
    fs.rmSync(restore.root, { recursive: true, force: true });
  }
});

test("P-23 rejects non-native date encodings in installed daemon evidence", () => {
  const route = fixture();
  const configMutation = fixture();
  try {
    mutate(route, route.session.evidence.daemonTranscript, (payload) => {
      payload.events[8].result.occurredAt = "2026-07-20T15:00:00.000Z";
    });
    assert.throws(
      () => validateP23InstalledSession(route.session, binding(route)),
      /native timestamp/u,
    );
    mutate(
      configMutation,
      configMutation.session.evidence.daemonTranscript,
      (payload) => {
        payload.events[6].result.snapshot.providers[0].credentialSlots[0].updatedAt =
          "2026-07-20T15:00:00.000Z";
      },
    );
    assert.throws(
      () =>
        validateP23InstalledSession(
          configMutation.session,
          binding(configMutation),
        ),
      /native timestamp/u,
    );
  } finally {
    fs.rmSync(route.root, { recursive: true, force: true });
    fs.rmSync(configMutation.root, { recursive: true, force: true });
  }
});
