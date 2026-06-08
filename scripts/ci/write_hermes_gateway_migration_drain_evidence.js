#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "..", "..");
const PRIVACY_MARKER = "aggregate_counts_only_no_document_values_or_identifiers";
const DEFAULT_REGION = "us-central1";
const SIGNAL_REQUIRED_ENV = "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED";

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
    plaintextFields: ["fileName", "contentType"],
  },
];

const CLASSIFICATIONS = [
  "signalRead",
  "knownLegacyRelay",
  "knownLegacyRatchet",
  "knownLegacyPlaintext",
  "unreadable",
  "malformed",
  "unknownSchema",
  "parserMisses",
];
const SIGNAL_ENVELOPE_FORMAT_VERSION = 1;
const SIGNAL_RELAY_KEY_VERSION = 4;
const SIGNAL_TRANSPORT_ENCRYPTION = "signal-doubleratchet-pqxdh-v1";
const SIGNAL_MAX_MESSAGE_B64 = 1_100_000;
const SIGNAL_MAX_ID = 160;
const SIGNAL_MAX_LABEL = 120;
const SIGNAL_MAX_COUNTER = 9_007_199_254_740_991;

function emptyCounts() {
  return Object.fromEntries(CLASSIFICATIONS.map((name) => [name, 0]));
}

function hasOwn(data, field) {
  return Object.prototype.hasOwnProperty.call(data, field) && data[field] !== undefined && data[field] !== null;
}

function hasSchemaVersion(data) {
  return Object.prototype.hasOwnProperty.call(data, "schemaVersion") && data.schemaVersion !== undefined && data.schemaVersion !== null;
}

function isKnownLegacyPlaintextDocument(data, plaintextFields = []) {
  if (hasSchemaVersion(data)) return false;
  return plaintextFields.some((field) => hasOwn(data, field));
}

function isAllowedGatewayDocumentPath(documentPath, collectionGroup) {
  const segments = String(documentPath ?? "").split("/");
  if (segments.length !== 4 || segments.some((segment) => segment.length === 0)) return false;
  if (segments[0] !== "users") return false;
  if (collectionGroup && segments[2] !== collectionGroup) return false;
  return COLLECTIONS.some((collection) => collection.collectionGroup === segments[2]);
}

function recordOrUndefined(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
}

function boundedText(raw, maxLength) {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (!value || value.length > maxLength || /[\r\n|]/u.test(value)) return undefined;
  return value;
}

function counter(raw) {
  const value = typeof raw === "number" ? Math.floor(raw) : Number(raw);
  if (!Number.isSafeInteger(value) || value < 0 || value > SIGNAL_MAX_COUNTER) return undefined;
  return value;
}

function base64Within(raw, maxLength) {
  if (typeof raw !== "string") return undefined;
  const value = raw.trim();
  if (
    !value ||
    value.length > maxLength ||
    value.length % 4 !== 0 ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u.test(value)
  ) {
    return undefined;
  }
  try {
    if (Buffer.from(value, "base64").toString("base64") !== value) return undefined;
  } catch {
    return undefined;
  }
  return value;
}

function isValidGatewaySignalEnvelope(raw) {
  const envelope = recordOrUndefined(raw);
  if (!envelope) return false;
  if (counter(envelope.signalEnvelopeFormatVersion) !== SIGNAL_ENVELOPE_FORMAT_VERSION) return false;
  if (envelope.mode !== "transport") return false;
  if (counter(envelope.relayKeyVersion) !== SIGNAL_RELAY_KEY_VERSION) return false;
  if (envelope.relayEncryption !== SIGNAL_TRANSPORT_ENCRYPTION) return false;

  const ciphertextLayer = recordOrUndefined(envelope.ciphertextLayer);
  if (!ciphertextLayer) return false;
  if (!base64Within(ciphertextLayer.payloadCiphertextB64, SIGNAL_MAX_MESSAGE_B64)) return false;
  if (!boundedText(ciphertextLayer.payloadAADLabel, SIGNAL_MAX_LABEL)) return false;
  if (counter(ciphertextLayer.schemaVersion) === undefined) return false;

  const keyDelivery = recordOrUndefined(envelope.keyDelivery);
  if (!keyDelivery || keyDelivery.scheme !== SIGNAL_TRANSPORT_ENCRYPTION) return false;
  if (keyDelivery.signalMessageType !== 2 && keyDelivery.signalMessageType !== 3) return false;
  if (!base64Within(keyDelivery.signalMessageB64, SIGNAL_MAX_MESSAGE_B64)) return false;
  if (!boundedText(keyDelivery.senderIdentityKeyId, SIGNAL_MAX_ID)) return false;
  if (keyDelivery.ratchetEpochHint !== undefined && counter(keyDelivery.ratchetEpochHint) === undefined) return false;

  const binding = recordOrUndefined(envelope.binding);
  if (!binding) return false;
  if (!boundedText(binding.uid, SIGNAL_MAX_ID)) return false;
  if (binding.scope !== "gateway" || binding.mode !== "transport") return false;
  if (counter(binding.formatVersion) !== SIGNAL_ENVELOPE_FORMAT_VERSION) return false;
  if (!boundedText(binding.clientId, SIGNAL_MAX_ID)) return false;
  if (!boundedText(binding.slotId, SIGNAL_MAX_ID)) return false;
  if (binding.collection !== undefined || binding.docId !== undefined || binding.field !== undefined) return false;

  return true;
}

function classifyGatewayDocument(data, plaintextFields = []) {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    return "unreadable";
  }
  if (data.__malformed === true) {
    return "malformed";
  }
  if (data.__parserMiss === true) {
    return "parserMisses";
  }
  if (data.__unreadable === true || data.unreadable === true) {
    return "unreadable";
  }
  if (hasOwn(data, "signalEnvelope") || data.signalRead === true || data.cryptoMode === "signal") {
    return isValidGatewaySignalEnvelope(data.signalEnvelope) ? "signalRead" : "malformed";
  }
  if (hasOwn(data, "relayEnvelope") || hasOwn(data, "legacyRelayEnvelope")) {
    return "knownLegacyRelay";
  }
  if (hasOwn(data, "ratchetEnvelope") || hasOwn(data, "legacyRatchetEnvelope")) {
    return "knownLegacyRatchet";
  }
  if (isKnownLegacyPlaintextDocument(data, plaintextFields)) {
    return "knownLegacyPlaintext";
  }
  return "unknownSchema";
}

function summarizeDocuments(documents, collection, { sampleLimit = documents.length, truncated = false } = {}) {
  const counts = emptyCounts();
  for (const data of documents) {
    counts[classifyGatewayDocument(data, collection.plaintextFields)] += 1;
  }
  return {
    collectionGroup: collection.collectionGroup,
    sampleLimit,
    sampled: documents.length,
    truncated,
    counts,
  };
}

function envFlagEnabled(raw) {
  return ["1", "true", "yes", "on"].includes(String(raw ?? "").trim().toLowerCase());
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
    "--format=json(metadata.name,status.latestReadyRevisionName,status.conditions,status.url)",
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

function serviceModeFromDescriptions(serviceDescription, readyRevision) {
  const env = readyRevision?.spec?.containers?.[0]?.env ?? [];
  const flag = Array.isArray(env) ? env.find((entry) => entry?.name === SIGNAL_REQUIRED_ENV) : undefined;
  const ready = (serviceDescription?.status?.conditions ?? []).find((condition) => condition?.type === "Ready");
  return {
    service: serviceDescription?.metadata?.name ?? "",
    latestReadyRevision: serviceDescription?.status?.latestReadyRevisionName ?? "",
    url: serviceDescription?.status?.url ?? "",
    signalRequired: ready?.status === "True" && envFlagEnabled(flag?.value),
  };
}

function collectRuntimeModeFromGcloud({ projectId, region = DEFAULT_REGION }) {
  const services = ["burnbarhermesgateway", "enqueuehermesgatewayevent"].map((service) => {
    const description = describeCloudRunService({ service, projectId, region });
    const latestReadyRevision = description?.status?.latestReadyRevisionName;
    const readyRevision = latestReadyRevision
      ? describeCloudRunRevision({ revision: latestReadyRevision, projectId, region })
      : undefined;
    return serviceModeFromDescriptions(description, readyRevision);
  });
  const signalRequired = services.length > 0 && services.every((service) => service.signalRequired === true);
  return {
    signalRequired,
    signalEnvelopeWritesEnabled: signalRequired,
    legacyRelayWritesEnabled: !signalRequired,
    legacyRatchetWritesEnabled: !signalRequired,
    legacyPlaintextWritesEnabled: false,
    modeSource: "gcloud run services describe + gcloud run revisions describe; status.conditions + readyRevision env",
    services,
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
  return { admin, db: admin.firestore() };
}

async function collectCollection(db, admin, collection, { pageSize, maxDocsPerCollection }) {
  const documents = [];
  let cursor;
  let truncated = false;
  while (documents.length <= maxDocsPerCollection) {
    const remainingWithSentinel = maxDocsPerCollection - documents.length + 1;
    if (remainingWithSentinel <= 0) {
      truncated = true;
      break;
    }
    const queryLimit = Math.min(pageSize, remainingWithSentinel);
    let query = db.collectionGroup(collection.collectionGroup).orderBy(admin.firestore.FieldPath.documentId()).limit(queryLimit);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      if (documents.length >= maxDocsPerCollection) {
        truncated = true;
        break;
      }
      if (isAllowedGatewayDocumentPath(doc.ref?.path, collection.collectionGroup)) {
        documents.push(doc.data());
      } else {
        documents.push({ __outOfScopePath: true });
      }
    }
    if (truncated) break;
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < queryLimit) break;
  }
  return summarizeDocuments(documents, collection, { sampleLimit: maxDocsPerCollection, truncated });
}

async function collectLiveEvidence(options) {
  const { admin, db } = initializeFirestore(options);
  const collections = {};
  for (const collection of COLLECTIONS) {
    collections[collection.id] = await collectCollection(db, admin, collection, options);
  }
  return buildEvidence({
    deployedCommit: options.deployedCommit,
    sourceLocation: options.sourceLocation,
    dependencyLocks: options.dependencyLocks,
    writePath: options.writePath,
    collections,
  });
}

function buildEvidence({ deployedCommit, sourceLocation, dependencyLocks, writePath, collections }) {
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    privacy: PRIVACY_MARKER,
    release: {
      deployedCommit,
      sourceLocation,
      dependencyLocks,
    },
    writePath,
    collections,
  };
}

function parseArgs(argv) {
  const options = {
    output: undefined,
    deployedCommit: undefined,
    sourceLocation: undefined,
    projectId: undefined,
    region: DEFAULT_REGION,
    runtimeModeFromGcloud: false,
    dependencyLocks: ["functions/package-lock.json", "packages/signal-envelope-contracts/package-lock.json"],
    pageSize: 500,
    maxDocsPerCollection: 50000,
    fixture: undefined,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[index];
    };
    if (arg === "--output") options.output = next();
    else if (arg === "--deployed-commit") options.deployedCommit = next();
    else if (arg === "--source-location") options.sourceLocation = next();
    else if (arg === "--project-id") options.projectId = next();
    else if (arg === "--region") options.region = next();
    else if (arg === "--runtime-mode-from-gcloud") options.runtimeModeFromGcloud = true;
    else if (arg === "--dependency-lock") options.dependencyLocks.push(next());
    else if (arg === "--fixture") options.fixture = next();
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!options.deployedCommit) throw new Error("--deployed-commit is required");
  if (!options.sourceLocation) throw new Error("--source-location is required");
  if (options.runtimeModeFromGcloud) {
    options.writePath = collectRuntimeModeFromGcloud(options);
  } else {
    options.writePath = {
      signalRequired: false,
      signalEnvelopeWritesEnabled: false,
      legacyRelayWritesEnabled: true,
      legacyRatchetWritesEnabled: true,
      legacyPlaintextWritesEnabled: false,
      modeSource: `${SIGNAL_REQUIRED_ENV}=false`,
      services: [],
    };
  }
  return options;
}

function writeEvidence(evidence, output) {
  const body = `${JSON.stringify(evidence, null, 2)}\n`;
  if (output) {
    fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
    fs.writeFileSync(output, body, "utf8");
  } else {
    process.stdout.write(body);
  }
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  let evidence;
  if (options.fixture) {
    const fixture = JSON.parse(fs.readFileSync(options.fixture, "utf8"));
    const collections = {};
    for (const collection of COLLECTIONS) {
      collections[collection.id] = summarizeDocuments(fixture[collection.id] ?? [], collection);
    }
    evidence = buildEvidence({
      deployedCommit: options.deployedCommit,
      sourceLocation: options.sourceLocation,
      dependencyLocks: options.dependencyLocks,
      writePath: options.writePath,
      collections,
    });
  } else {
    evidence = await collectLiveEvidence(options);
  }
  writeEvidence(evidence, options.output);
}

module.exports = {
  COLLECTIONS,
  PRIVACY_MARKER,
  classifyGatewayDocument,
  isValidGatewaySignalEnvelope,
  collectLiveEvidence,
  collectCollection,
  summarizeDocuments,
  buildEvidence,
  isAllowedGatewayDocumentPath,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
