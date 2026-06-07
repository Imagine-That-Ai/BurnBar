#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  COLLECTIONS,
  PRIVACY_MARKER,
  classifyGatewayDocument,
} = require("./write_hermes_gateway_migration_drain_evidence.js");

const repoRoot = path.resolve(__dirname, "..", "..");
const EXECUTE_CONFIRMATION = "delete-legacy-hermes-gateway-records";
// Output privacy contract: aggregate_counts_only_no_document_values_or_identifiers.
const REQUIRED_WRITE_PATH_SERVICES = new Set(["burnbarhermesgateway", "enqueuehermesgatewayevent"]);
const TARGET_CLASSIFICATIONS = [
  "legacyHermesRelayRead",
  "legacyHermesRatchetRead",
  "legacyPlaintextRead",
  "unreadable",
];
const CLASSIFICATIONS = ["signalRead", ...TARGET_CLASSIFICATIONS];

function emptyClassificationCounts() {
  return Object.fromEntries(CLASSIFICATIONS.map((field) => [field, 0]));
}

function summarizeGatewayDrainDocuments(documents, collection, { execute = false, deleted = 0, truncated = false } = {}) {
  const classifications = emptyClassificationCounts();
  for (const data of documents) {
    classifications[classifyGatewayDocument(data, collection.plaintextFields)] += 1;
  }
  const eligible = TARGET_CLASSIFICATIONS.reduce((total, field) => total + classifications[field], 0);
  return {
    collectionGroup: collection.collectionGroup,
    scanned: documents.length,
    retainedSignal: classifications.signalRead,
    eligible,
    deleted: execute ? deleted : 0,
    dryRun: !execute,
    truncated,
    classifications,
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

function runtimeModeEvidenceErrors(raw) {
  const errors = [];
  const writePath = raw?.writePath;
  if (!writePath || typeof writePath !== "object" || Array.isArray(writePath)) {
    return ["runtime mode evidence writePath must be an object"];
  }
  const expected = {
    signalRequired: true,
    signalEnvelopeWritesEnabled: true,
    legacyRelayWritesEnabled: false,
    legacyRatchetWritesEnabled: false,
    legacyPlaintextWritesEnabled: false,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (writePath[key] !== value) {
      errors.push(`runtime mode evidence writePath.${key} must be ${value}`);
    }
  }
  const services = writePath.services;
  if (!Array.isArray(services) || services.length === 0) {
    errors.push("runtime mode evidence writePath.services must be a non-empty list");
    return errors;
  }
  const seenServices = new Set();
  for (const [index, service] of services.entries()) {
    if (!service || typeof service !== "object" || Array.isArray(service)) {
      errors.push(`runtime mode evidence writePath.services.${index} must be an object`);
      continue;
    }
    if (typeof service.service === "string") {
      seenServices.add(service.service);
    }
    if (service.signalRequired !== true) {
      errors.push(`runtime mode evidence writePath.services.${index}.signalRequired must be true`);
    }
  }
  for (const service of REQUIRED_WRITE_PATH_SERVICES) {
    if (!seenServices.has(service)) {
      errors.push(`runtime mode evidence missing required service: ${service}`);
    }
  }
  return errors;
}

function validateRuntimeModeEvidence(pathValue) {
  if (!pathValue) {
    return ["--runtime-mode-evidence is required when --execute is set"];
  }
  const evidencePath = path.resolve(pathValue);
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(evidencePath, "utf8"));
  } catch (error) {
    return [`runtime mode evidence is not readable JSON: ${error.message}`];
  }
  return runtimeModeEvidenceErrors(raw);
}

async function drainCollection(db, admin, collection, options) {
  const classifications = emptyClassificationCounts();
  let scanned = 0;
  let deleted = 0;
  let retainedSignal = 0;
  let cursor;
  let truncated = false;
  const writer = options.execute ? db.bulkWriter() : undefined;

  while (scanned < options.maxDocsPerCollection) {
    let query = db.collectionGroup(collection.collectionGroup).orderBy(admin.firestore.FieldPath.documentId()).limit(options.pageSize);
    if (cursor) {
      query = query.startAfter(cursor);
    }
    const snap = await query.get();
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      if (scanned >= options.maxDocsPerCollection) {
        truncated = true;
        break;
      }
      const classification = classifyGatewayDocument(doc.data(), collection.plaintextFields);
      classifications[classification] += 1;
      scanned += 1;
      if (classification === "signalRead") {
        retainedSignal += 1;
        continue;
      }
      if (writer) {
        writer.delete(doc.ref);
        deleted += 1;
      }
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < options.pageSize) {
      break;
    }
  }
  if (writer) {
    await writer.close();
  }

  const eligible = TARGET_CLASSIFICATIONS.reduce((total, field) => total + classifications[field], 0);
  return {
    collectionGroup: collection.collectionGroup,
    scanned,
    retainedSignal,
    eligible,
    deleted,
    dryRun: !options.execute,
    truncated,
    classifications,
  };
}

async function drainLiveGateway(options) {
  const { admin, db } = initializeFirestore(options);
  const collections = {};
  for (const collection of COLLECTIONS) {
    collections[collection.id] = await drainCollection(db, admin, collection, options);
  }
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    privacy: PRIVACY_MARKER,
    mode: options.execute ? "execute" : "dry_run",
    safety: {
      executeConfirmation: options.execute ? EXECUTE_CONFIRMATION : "not_requested",
      runtimeModeEvidence: options.runtimeModeEvidence || null,
    },
    collections,
  };
}

function parseArgs(argv) {
  const options = {
    execute: false,
    output: undefined,
    projectId: undefined,
    runtimeModeEvidence: undefined,
    confirmation: undefined,
    maxDocsPerCollection: 50_000,
    pageSize: 500,
    selfTest: false,
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
    } else if (arg === "--execute") {
      options.execute = true;
    } else if (arg === "--confirm") {
      options.confirmation = next();
    } else if (arg === "--runtime-mode-evidence") {
      options.runtimeModeEvidence = next();
    } else if (arg === "--output") {
      options.output = next();
    } else if (arg === "--project-id") {
      options.projectId = next();
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
  if (options.execute) {
    if (options.confirmation !== EXECUTE_CONFIRMATION) {
      throw new Error(`--execute requires --confirm ${EXECUTE_CONFIRMATION}`);
    }
    const runtimeErrors = validateRuntimeModeEvidence(options.runtimeModeEvidence);
    if (runtimeErrors.length > 0) {
      throw new Error(runtimeErrors.join("; "));
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
    console.log(`Wrote Hermes Gateway legacy drain evidence: ${outputPath}`);
  } else {
    process.stdout.write(body);
  }
}

function runSelfTest() {
  const events = COLLECTIONS.find((collection) => collection.id === "events");
  const summary = summarizeGatewayDrainDocuments(
    [
      { signalEnvelope: { signalEnvelopeFormatVersion: 1 } },
      { relayEnvelope: { payloadCiphertext: "x" } },
      { text: "legacy cleartext" },
      { schemaVersion: 4 },
    ],
    events,
  );
  assert.equal(summary.scanned, 4);
  assert.equal(summary.retainedSignal, 1);
  assert.equal(summary.eligible, 3);
  assert.equal(summary.deleted, 0);
  assert.equal(summary.dryRun, true);
  assert.equal(summary.classifications.signalRead, 1);
  assert.equal(summary.classifications.legacyHermesRelayRead, 1);
  assert.equal(summary.classifications.legacyPlaintextRead, 1);
  assert.equal(summary.classifications.unreadable, 1);

  assert.deepEqual(
    runtimeModeEvidenceErrors({
      writePath: {
        signalRequired: true,
        signalEnvelopeWritesEnabled: true,
        legacyRelayWritesEnabled: false,
        legacyRatchetWritesEnabled: false,
        legacyPlaintextWritesEnabled: false,
        services: [
          { service: "burnbarhermesgateway", signalRequired: true },
          { service: "enqueuehermesgatewayevent", signalRequired: true },
        ],
      },
    }),
    [],
  );
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.selfTest) {
    runSelfTest();
    console.log("PASS: Hermes Gateway legacy drain self-test passed");
    return;
  }
  const evidence = await drainLiveGateway(options);
  writeEvidence(evidence, options.output);
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  EXECUTE_CONFIRMATION,
  runtimeModeEvidenceErrors,
  summarizeGatewayDrainDocuments,
};
