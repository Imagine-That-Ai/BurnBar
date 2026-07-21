import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import zlib from "node:zlib";
import { captureP21InsightsProof } from "./capture-p21-insights-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  P21_PROOF_ROLE,
  validateP21InstalledSession,
  validateP21Proof,
} from "./lib/p21-insights-proof.mjs";
import { materializeP21InsightsSession } from "./materialize-p21-insights-session.mjs";
import {
  RELEASE_ARCHITECTURES,
  SUPPORT_ENVIRONMENTS,
  readRegularSnapshot,
} from "./lib/product-proof-closure.mjs";
import { validateProductRequirement } from "./product-validators/P-21.mjs";

const HEAD = "1".repeat(40);
const RUN_ID = "212121";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VERSION = "1.2.3";
const MARKER = "p21-fedcba0987654321";

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
  const base = path.join(process.cwd(), ".tmp/p21-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  const raw = path.join(root, "raw");
  fs.mkdirSync(raw);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-21",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const identity = attestation(root, raw);
  const started = Date.now() - 30_000;
  const at = (offset) => new Date(started + offset).toISOString();
  const markerEvents = [
    ["codex", "gpt-5.6-sol", 840, 210],
    ["claude", "claude-opus-4.6", 610, 190],
    ["gemini", "gemini-3-pro", 430, 120],
  ].map(([providerID, modelID, inputTokens, outputTokens], index) => ({
    idempotencyKey: `${MARKER}-${index}`,
    event: {
      providerID,
      modelID,
      inputTokens,
      outputTokens,
      cacheCreationTokens: 20 + index,
      cacheReadTokens: 80 + index,
      reasoningTokens: 30 + index,
      cost: 0.01 + index * 0.005,
      recordedAt: 800000000 + index,
      sessionID: `${MARKER}-session-${index}`,
      projectName: `P21 installed insights ${MARKER}`,
      confidence: "exact",
    },
  }));
  const prompt = `Summarize installed Insights evidence for ${MARKER}.`;
  json(path.join(raw, "insights-marker.json"), {
    marker: MARKER,
    prompt,
    events: markerEvents,
  });
  const response = (index, eventAt) => {
    const citation = { id: `citation-${index}`, label: "codex session" };
    return {
      usage: markerEvents.map((row) => row.event),
      sourceID: "daemon.usage.ledger",
      sourceLabel: "Linux daemon usage ledger · local rules",
      analysis: {
        requestID: `request-${index}`,
        generatedAt: new Date(Date.parse(eventAt) - 100).toISOString(),
        executiveSummary: "Three providers recorded bounded local usage.",
        citations: [citation],
        findings: [
          {
            id: "mix",
            title: "Provider mix",
            whyItMatters: "Routing is distributed.",
            recommendedAction: "Review scopes.",
            evidence: [citation],
          },
        ],
      },
    };
  };
  const daemonEvents = markerEvents.map((row, index) => ({
    phase: `record-${row.event.providerID}`,
    at: at(1000 + index * 1000),
    method: "daemon.usage.record",
    request: row,
    ok: true,
    error: null,
    result: {
      idempotencyKey: row.idempotencyKey,
      inserted: true,
      event: row.event,
    },
  }));
  for (const [index, phase] of [
    "insights-initial",
    "insights-refresh",
    "insights-restart",
  ].entries()) {
    const eventAt = at(5000 + index * 1000);
    daemonEvents.push({
      phase,
      at: eventAt,
      method: "daemon.usage.insights",
      request: { limit: 200, windowSeconds: 604800, prompt },
      ok: true,
      error: null,
      result: response(index + 1, eventAt),
    });
  }
  json(path.join(raw, "insights-daemon-transcript.json"), {
    producer: "openburnbar-p21-installed-insights-daemon-probe-v1",
    transport: "installed daemon AF_UNIX RPC",
    events: daemonEvents,
  });
  const ui = (phase, offset, pid, observed) => ({
    phase,
    at: at(offset),
    appPid: pid,
    marker: MARKER,
    manifestSha256: identity.manifestSha256,
    observed,
  });
  json(path.join(raw, "insights-ui-transcript.json"), {
    producer: "openburnbar-p21-installed-insights-ui-probe-v1",
    events: [
      ui("initial", 9000, 2101, {
        workspace: true,
        provenance: true,
        qualitative: true,
        fresh: true,
        citation: true,
        inspector: true,
      }),
      ui("configured", 10000, 2101, {
        compact: true,
        selectedWidget: "Model mix",
        compareCount: 3,
        comparison: true,
        provenanceColumns: 3,
        audit: true,
      }),
      ui("chat-handoff", 11000, 2101, { chat: true, followUp: true }),
      ui("restart", 12000, 2102, {
        compact: true,
        selectedWidget: "Model mix",
      }),
      ui("source-loss", 13000, 2102, {
        snapshotPreserved: true,
        degradedBanner: true,
      }),
    ],
  });
  for (const [index, name] of [
    "insights-initial.png",
    "insights-compare.png",
    "insights-restart.png",
    "insights-source-loss.png",
  ].entries())
    write(path.join(raw, name), png(21 + index));
  const materialized = materializeP21InsightsSession(
    {
      repoRoot: root,
      outputRoot: input,
      rawEvidenceDir: raw,
      environmentId: ENVIRONMENT,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      packageVersion: VERSION,
      ...identity,
      compositor: "Mutter",
    },
    {
      installedVerifier: () => ({}),
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return { root, raw, input, identity, materialized, endedAt: at(13000) };
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
    requirementId: "P-21",
    checkId: "p-21.insights",
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    releaseClosure: {
      document: {
        schemaVersion: 3,
        targetHead: HEAD,
        sourceCommit: HEAD,
        status: "passed",
        requirementId: "P-21",
        environmentId: ENVIRONMENT,
        version: VERSION,
        blockers: [],
        architectures: [...RELEASE_ARCHITECTURES],
        supportEnvironments: [...SUPPORT_ENVIRONMENTS],
        selectedPackage: { architecture: "aarch64", format: "deb" },
        candidate: { runId: RUN_ID, artifactDigest: DIGEST },
        packageManifestSignature: value.materialized.document.package.signature,
        proofs: [
          { role: "aggregate-product-proof-closure", ...aggregate },
          { role: P21_PROOF_ROLE, ...proof },
        ],
      },
    },
    subjects: {
      release: aggregate,
      packageManifest: value.materialized.document.package.manifest,
      packages: [pkg],
      runtimes: [runtime],
      installation: [aggregate],
      environment,
      features: [],
    },
  };
}

test("P-21 materializer, capture, and product validator close installed Insights proof", async () => {
  const value = fixture();
  try {
    const captured = captureP21InsightsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.materialized.output,
      },
      {
        resolveHead: () => HEAD,
        now: () => new Date(Date.parse(value.endedAt) + 1),
      },
    );
    const validated = validateP21Proof({
      ...binding(value),
      snapshot: readRegularSnapshot(
        value.root,
        record(value.root, captured.output).path,
        "P-21 proof",
      ),
    });
    assert.equal(validated.proof.claim.daemonEvents, 6);
    assert.equal(validated.proof.claim.compareScopes, 3);
    assert.ok(validated.proof.claim.citationCount >= 1);
    const result = await validateProductRequirement(
      context(value, captured.output),
    );
    assert.equal(result.status, "passed");
    assert.deepEqual(
      JSON.parse(fs.readFileSync(captured.registration)).artifacts,
      [
        {
          role: P21_PROOF_ROLE,
          path: "feature-artifacts/p21-installed-insights-proof.json",
        },
      ],
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-21 rejects freshness, ordering, provenance, citation, UI, and screenshot mutations", () => {
  const cases = [
    [
      "future timestamp",
      (value, document) =>
        mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
          payload.events[3].result.analysis.generatedAt = new Date(
            Date.parse(payload.events[3].at) + 60000,
          ).toISOString();
        }),
      /future/u,
    ],
    [
      "out-of-order refresh",
      (value, document) =>
        mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
          payload.events[4].at = payload.events[3].at;
        }),
      /out of order/u,
    ],
    [
      "noncanonical event timestamp",
      (value, document) =>
        mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
          payload.events[3].at = payload.events[3].at.replace(/\.\d{3}Z$/u, "Z");
        }),
      /timestamp is invalid/u,
    ],
    [
      "missing provenance",
      (value, document) =>
        mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
          payload.events[3].result.sourceID = "renderer.sample";
        }),
      /authoritative/u,
    ],
    [
      "missing citations",
      (value, document) =>
        mutateArtifact(value, document.evidence.daemonTranscript, (payload) => {
          payload.events[3].result.analysis.citations = [];
        }),
      /qualitative response|citations/u,
    ],
    [
      "lost persistence",
      (value, document) =>
        mutateArtifact(value, document.evidence.uiTranscript, (payload) => {
          payload.events[3].observed.compact = false;
        }),
      /Insights UI/u,
    ],
    [
      "lost source preservation",
      (value, document) =>
        mutateArtifact(value, document.evidence.uiTranscript, (payload) => {
          payload.events[4].observed.snapshotPreserved = false;
        }),
      /Insights UI/u,
    ],
    [
      "replayed screenshot",
      (value, document) => {
        const initial = path.join(
          value.root,
          document.evidence.initialScreenshot.path,
        );
        const restart = path.join(
          value.root,
          document.evidence.restartScreenshot.path,
        );
        fs.copyFileSync(initial, restart);
        Object.assign(
          document.evidence.restartScreenshot,
          record(value.root, restart),
        );
      },
      /replay/u,
    ],
  ];
  for (const [label, mutate, pattern] of cases) {
    const value = fixture();
    try {
      const document = structuredClone(value.materialized.document);
      mutate(value, document);
      assert.throws(
        () =>
          validateP21InstalledSession(document, binding(value), {
            repoRoot: value.root,
          }),
        pattern,
        label,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});

test("P-21 capture rejects checkout and source-byte substitution", () => {
  const value = fixture();
  try {
    assert.throws(
      () =>
        captureP21InsightsProof(
          {
            ...binding(value),
            inputRoot: value.input,
            sessionReport: value.materialized.output,
          },
          { resolveHead: () => "f".repeat(40) },
        ),
      /target HEAD/u,
    );
    const captured = captureP21InsightsProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.materialized.output,
      },
      {
        resolveHead: () => HEAD,
        now: () => new Date(Date.parse(value.endedAt) + 1),
      },
    );
    fs.appendFileSync(value.materialized.output, " \n");
    assert.throws(
      () =>
        validateP21Proof({
          ...binding(value),
          snapshot: readRegularSnapshot(
            value.root,
            record(value.root, captured.output).path,
            "P-21 proof",
          ),
        }),
      /bytes changed|sha256|size/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
