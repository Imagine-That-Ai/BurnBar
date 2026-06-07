#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "..", "..");

const PRIVACY_MARKER = "aggregate_counts_only_no_document_values_or_identifiers";
const SOURCE_AVAILABILITY = "docs/legal/SOURCE_AVAILABILITY.md";
const DEFAULT_DEPENDENCY_LOCKS = ["package-lock.json", "pyproject.toml"];
const SIGNAL_REQUIRED_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED";
const DEFAULT_GCLOUD_REGION = "us-central1";
const DEFAULT_WRITE_PATH_SERVICES = ["burnbarhermesgateway", "enqueuehermesgatewayevent"];
const COLLECTIONS = [
  {
    id: "events",
    collectionGroup: "hermes_gateway_events",
    plaintextFields: ["text", "senderDisplayName", "threadId"],
  },
  {
    id: "messages",
    collectionGroup: "hermes_gateway_messages",
    plaintextFields: ["text", "threadId", "replyToEventId"],
  },
  {
    id: "attachments",
    collectionGroup: "hermes_gateway_attachments",
    plaintextFields: ["fileName"],
  },
];
const COUNT_FIELDS = [
  "total",
  "signalRead",
  "legacyHermesRelayRead",
  "legacyHermesRatchetRead",
  "legacyPlaintextRead",
  "unreadable",
];

function emptyCounts() {
  return Object.fromEntries(COUNT_FIELDS.map((field) => [field, 0]));
}

function hasNonEmptyField(data, field) {
  return Object.prototype.hasOwnProperty.call(data, field) && data[field] !== undefined && data[field] !== null;
}

function classifyGatewayDocument(data, plaintextFields) {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return "unreadable";
  }
  if (hasNonEmptyField(data, "signalEnvelope")) {
    return "signalRead";
  }
  if (hasNonEmptyField(data, "ratchetEnvelope")) {
    return "legacyHermesRatchetRead";
  }
  if (hasNonEmptyField(data, "relayEnvelope")) {
    return "legacyHermesRelayRead";
  }
  if (plaintextFields.some((field) => hasNonEmptyField(data, field))) {
    return "legacyPlaintextRead";
  }
  return "unreadable";
}

function summarizeDocuments(documents, collection, { sampleLimit, truncated = false }) {
  const counts = emptyCounts();
  for (const data of documents) {
    const field = classifyGatewayDocument(data, collection.plaintextFields);
    counts[field] += 1;
  }
  counts.total = documents.length;
  return {
    collectionGroup: collection.collectionGroup,
    sampleLimit,
    sampled: documents.length,
    truncated,
    counts,
  };
}

function buildWritePathEvidence({ signalRequiredMode, modeSource }) {
  return {
    signalRequired: signalRequiredMode === true,
    signalEnvelopeWritesEnabled: signalRequiredMode === true,
    legacyRelayWritesEnabled: signalRequiredMode !== true,
    legacyRatchetWritesEnabled: signalRequiredMode !== true,
    legacyPlaintextWritesEnabled: false,
    modeSource: modeSource || `${SIGNAL_REQUIRED_ENV}=false`,
    services: DEFAULT_WRITE_PATH_SERVICES.map((service) => ({
      service,
      latestReadyRevision: "self-test-manual",
      url: `https://${service}.example.com`,
      signalRequired: signalRequiredMode === true,
    })),
  };
}

function envFlagEnabled(raw) {
  if (raw == null) {
    return false;
  }
  return ["1", "true", "yes", "on"].includes(String(raw).trim().toLowerCase());
}

function serviceModeFromDescription(description) {
  const service = description?.metadata?.name;
  const latestReadyRevision = description?.status?.latestReadyRevisionName;
  const url = description?.status?.url;
  const ready = (description?.status?.conditions ?? []).find((condition) => condition?.type === "Ready");
  const env = description?.readyRevision?.spec?.containers?.[0]?.env ?? [];
  const flag = Array.isArray(env) ? env.find((entry) => entry?.name === SIGNAL_REQUIRED_ENV) : undefined;
  return {
    service: typeof service === "string" ? service : "",
    latestReadyRevision: typeof latestReadyRevision === "string" ? latestReadyRevision : "",
    url: typeof url === "string" ? url : "",
    signalRequired: ready?.status === "True" && envFlagEnabled(flag?.value),
  };
}

function buildWritePathEvidenceFromServices(services, { modeSource }) {
  const signalRequiredMode = services.length > 0 && services.every((service) => service.signalRequired === true);
  return {
    signalRequired: signalRequiredMode,
    signalEnvelopeWritesEnabled: signalRequiredMode,
    legacyRelayWritesEnabled: !signalRequiredMode,
    legacyRatchetWritesEnabled: !signalRequiredMode,
    legacyPlaintextWritesEnabled: false,
    modeSource,
    services,
  };
}

function describeCloudRunService({ service, projectId, region }) {
  const args = [
    "run",
    "services",
    "describe",
    service,
    "--project",
    projectId,
    "--region",
    region,
    "--format=json(metadata.name,status.latestReadyRevisionName,status.conditions,status.url,spec.template.spec.containers[0].env)",
  ];
  const result = spawnSync("gcloud", args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`gcloud run services describe ${service} failed: ${(result.stderr || result.stdout).trim()}`);
  }
  return JSON.parse(result.stdout);
}

function describeCloudRunRevision({ revision, projectId, region }) {
  const args = [
    "run",
    "revisions",
    "describe",
    revision,
    "--project",
    projectId,
    "--region",
    region,
    "--format=json(spec.containers[0].env)",
  ];
  const result = spawnSync("gcloud", args, { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(`gcloud run revisions describe ${revision} failed: ${(result.stderr || result.stdout).trim()}`);
  }
  return JSON.parse(result.stdout);
}

function collectWritePathEvidenceFromGcloud({ projectId, region, gcloudServices }) {
  if (!projectId) {
    throw new Error("--project-id is required with --runtime-mode-from-gcloud");
  }
  const services = gcloudServices.map((service) => {
    const description = describeCloudRunService({ service, projectId, region });
    const latestReadyRevision = description?.status?.latestReadyRevisionName;
    if (typeof latestReadyRevision === "string" && latestReadyRevision.trim()) {
      description.readyRevision = describeCloudRunRevision({ revision: latestReadyRevision, projectId, region });
    }
    return serviceModeFromDescription(description);
  });
  return buildWritePathEvidenceFromServices(services, {
    modeSource: `gcloud run services describe ${gcloudServices.join(",")} --project ${projectId} --region ${region}`,
  });
}

function buildEvidence({ deployedCommit, sourceLocation, dependencyLocks, writePath, collections, generatedAt }) {
  return {
    schemaVersion: 1,
    generatedAt: generatedAt || new Date().toISOString(),
    privacy: PRIVACY_MARKER,
    release: {
      deployedCommit,
      sourceLocation,
      sourceAvailability: SOURCE_AVAILABILITY,
      dependencyLocks,
    },
    writePath,
    collections,
  };
}

function requireFirebaseAdmin() {
  return require(path.join(repoRoot, "functions/node_modules/firebase-admin"));
}

function initializeFirestore({ projectId }) {
  const admin = requireFirebaseAdmin();
  if (admin.apps.length === 0) {
    admin.initializeApp(projectId ? { projectId } : undefined);
  }
  return {
    admin,
    db: admin.firestore(),
  };
}

async function collectCollection(db, admin, collection, { pageSize, maxDocsPerCollection }) {
  const documents = [];
  let cursor;
  let truncated = false;
  while (documents.length < maxDocsPerCollection) {
    let query = db.collectionGroup(collection.collectionGroup).orderBy(admin.firestore.FieldPath.documentId()).limit(pageSize);
    if (cursor) {
      query = query.startAfter(cursor);
    }
    const snap = await query.get();
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      if (documents.length >= maxDocsPerCollection) {
        truncated = true;
        break;
      }
      documents.push(doc.data());
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < pageSize) {
      break;
    }
  }
  return summarizeDocuments(documents, collection, { sampleLimit: maxDocsPerCollection, truncated });
}

async function collectLiveEvidence(options) {
  const { admin, db } = initializeFirestore(options);
  const collections = {};
  for (const collection of COLLECTIONS) {
    collections[collection.id] = await collectCollection(db, admin, collection, options);
  }
  const writePath = options.runtimeModeFromGcloud
    ? collectWritePathEvidenceFromGcloud(options)
    : buildWritePathEvidence(options);
  return buildEvidence({
    deployedCommit: options.deployedCommit,
    sourceLocation: options.sourceLocation,
    dependencyLocks: options.dependencyLocks,
    writePath,
    collections,
  });
}

function parseArgs(argv) {
  const options = {
    dependencyLocks: [...DEFAULT_DEPENDENCY_LOCKS],
    maxDocsPerCollection: 50_000,
    pageSize: 500,
    output: undefined,
    projectId: undefined,
    selfTest: false,
    dependencyLocksOverridden: false,
    deployedCommit: undefined,
    sourceLocation: undefined,
    signalRequiredMode: false,
    modeSource: undefined,
    runtimeModeFromGcloud: false,
    region: DEFAULT_GCLOUD_REGION,
    gcloudServices: [...DEFAULT_WRITE_PATH_SERVICES],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) {
        throw new Error(`${arg} requires a value`);
      }
      return argv[index];
    };
    if (arg === "--self-test") {
      options.selfTest = true;
    } else if (arg === "--output") {
      options.output = next();
    } else if (arg === "--project-id") {
      options.projectId = next();
    } else if (arg === "--deployed-commit") {
      options.deployedCommit = next();
    } else if (arg === "--source-location") {
      options.sourceLocation = next();
    } else if (arg === "--signal-required-mode") {
      options.signalRequiredMode = true;
      if (!options.modeSource) {
        options.modeSource = `${SIGNAL_REQUIRED_ENV}=true`;
      }
    } else if (arg === "--mode-source") {
      options.modeSource = next();
    } else if (arg === "--runtime-mode-from-gcloud") {
      options.runtimeModeFromGcloud = true;
    } else if (arg === "--region") {
      options.region = next();
    } else if (arg === "--gcloud-service") {
      if (!options.gcloudServicesOverridden) {
        options.gcloudServices = [];
        options.gcloudServicesOverridden = true;
      }
      options.gcloudServices.push(next());
    } else if (arg === "--dependency-lock") {
      if (!options.dependencyLocksOverridden) {
        options.dependencyLocks = [];
        options.dependencyLocksOverridden = true;
      }
      options.dependencyLocks.push(next());
    } else if (arg === "--max-docs-per-collection") {
      options.maxDocsPerCollection = Number(next());
    } else if (arg === "--page-size") {
      options.pageSize = Number(next());
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!Number.isInteger(options.maxDocsPerCollection) || options.maxDocsPerCollection < 1) {
    throw new Error("--max-docs-per-collection must be a positive integer");
  }
  if (!Number.isInteger(options.pageSize) || options.pageSize < 1 || options.pageSize > 1000) {
    throw new Error("--page-size must be an integer from 1 to 1000");
  }
  if (!options.gcloudServices.length) {
    throw new Error("--gcloud-service must name at least one service when overriding defaults");
  }
  if (!options.selfTest) {
    if (!options.deployedCommit) {
      throw new Error("--deployed-commit is required for live evidence");
    }
    if (!options.sourceLocation) {
      throw new Error("--source-location is required for live evidence");
    }
  }
  return options;
}

function writeEvidence(evidence, output) {
  const body = `${JSON.stringify(evidence, null, 2)}\n`;
  if (output) {
    const outputPath = path.resolve(output);
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, body, "utf8");
    console.log(`Wrote Hermes Gateway migration-drain evidence: ${outputPath}`);
  } else {
    process.stdout.write(body);
  }
}

function cleanSelfTestEvidence() {
  const signalDoc = { schemaVersion: 4, signalEnvelope: { signalEnvelopeFormatVersion: 1 } };
  const collections = {};
  for (const collection of COLLECTIONS) {
    collections[collection.id] = summarizeDocuments([signalDoc, signalDoc], collection, {
      sampleLimit: 50,
      truncated: false,
    });
  }
  return buildEvidence({
    deployedCommit: "0123456789abcdef0123456789abcdef01234567",
    sourceLocation: "https://example.com/openburnbar/source/0123456789abcdef0123456789abcdef01234567",
    dependencyLocks: DEFAULT_DEPENDENCY_LOCKS,
    writePath: buildWritePathEvidence({
      signalRequiredMode: true,
      modeSource: `${SIGNAL_REQUIRED_ENV}=true self-test`,
    }),
    generatedAt: "2026-06-06T00:00:00.000Z",
    collections,
  });
}

function runSelfTest() {
  const events = COLLECTIONS.find((collection) => collection.id === "events");
  const attachments = COLLECTIONS.find((collection) => collection.id === "attachments");
  assert.equal(classifyGatewayDocument({ signalEnvelope: {} }, events.plaintextFields), "signalRead");
  assert.equal(classifyGatewayDocument({ ratchetEnvelope: {} }, events.plaintextFields), "legacyHermesRatchetRead");
  assert.equal(classifyGatewayDocument({ relayEnvelope: {} }, events.plaintextFields), "legacyHermesRelayRead");
  assert.equal(classifyGatewayDocument({ text: "legacy body" }, events.plaintextFields), "legacyPlaintextRead");
  assert.equal(classifyGatewayDocument({ fileName: "legacy.pdf" }, attachments.plaintextFields), "legacyPlaintextRead");
  assert.equal(classifyGatewayDocument({ schemaVersion: 4 }, events.plaintextFields), "unreadable");

  const evidence = cleanSelfTestEvidence();
  assert.equal(evidence.privacy, PRIVACY_MARKER);
  assert.deepEqual(Object.keys(evidence.collections).sort(), ["attachments", "events", "messages"]);
  assert.equal(evidence.collections.events.counts.signalRead, 2);
  assert.equal(evidence.collections.events.counts.total, 2);
  assert.equal(evidence.writePath.signalRequired, true);
  assert.equal(evidence.writePath.legacyRelayWritesEnabled, false);
  assert.deepEqual(
    evidence.writePath.services.map((service) => service.service).sort(),
    [...DEFAULT_WRITE_PATH_SERVICES].sort(),
  );
  assert.equal(JSON.stringify(evidence).includes("legacy body"), false);
  return evidence;
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.selfTest) {
    const evidence = runSelfTest();
    if (options.output) {
      writeEvidence(evidence, options.output);
    } else {
      console.log("PASS: Hermes Gateway migration-drain collector self-test passed");
    }
    return;
  }
  const evidence = await collectLiveEvidence(options);
  writeEvidence(evidence, options.output);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  COLLECTIONS,
  PRIVACY_MARKER,
  buildEvidence,
  classifyGatewayDocument,
  cleanSelfTestEvidence,
  describeCloudRunRevision,
  serviceModeFromDescription,
  buildWritePathEvidenceFromServices,
  summarizeDocuments,
};
