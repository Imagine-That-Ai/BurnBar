#!/usr/bin/env node
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const {
  COLLECTIONS,
  PRIVACY_MARKER,
  classifyGatewayDocument,
  summarizeDocuments,
} = require("./write_hermes_gateway_migration_drain_evidence.js");

const repoRoot = path.resolve(__dirname, "..", "..");
const EXECUTE_CONFIRMATION = "delete-legacy-hermes-gateway-records";
const LIVE_PRODUCTION_ACK_PREFIX = "mutate-production-hermes-gateway-records-in-";
const DELETABLE = new Set(["knownLegacyRelay", "knownLegacyRatchet", "knownLegacyPlaintext"]);
const BLOCKERS = new Set(["unreadable", "malformed", "unknownSchema", "parserMisses"]);
const REQUIRED_SERVICES = new Set(["burnbarhermesgateway", "enqueuehermesgatewayevent"]);
// Output privacy contract: aggregate_counts_only_no_document_values_or_identifiers.
// Private quarantine/export outputs intentionally break that public evidence
// contract and must not be committed or published.

function validGatewaySignalEnvelope() {
  return {
    signalEnvelopeFormatVersion: 1,
    mode: "transport",
    relayKeyVersion: 4,
    relayEncryption: "signal-doubleratchet-pqxdh-v1",
    ciphertextLayer: {
      payloadCiphertextB64: Buffer.from("payload").toString("base64"),
      payloadAADLabel: "gateway-event",
      schemaVersion: 1,
    },
    keyDelivery: {
      scheme: "signal-doubleratchet-pqxdh-v1",
      signalMessageType: 3,
      signalMessageB64: Buffer.from("signal-message").toString("base64"),
      senderIdentityKeyId: "sender-identity",
    },
    binding: {
      uid: "user",
      scope: "gateway",
      clientId: "client",
      slotId: "event",
      mode: "transport",
      formatVersion: 1,
    },
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
    if (writePath[key] !== value) errors.push(`runtime mode evidence writePath.${key} must be ${value}`);
  }
  const services = new Set((writePath.services ?? []).map((service) => service?.service));
  for (const service of REQUIRED_SERVICES) {
    if (!services.has(service)) errors.push(`runtime mode evidence missing required service: ${service}`);
  }
  return errors;
}

function validateRuntimeModeEvidence(filePath, { requireLiveEvidence = false } = {}) {
  if (!filePath) return ["--runtime-mode-evidence is required when --execute is set"];
  try {
    const raw = JSON.parse(fs.readFileSync(filePath, "utf8"));
    const errors = runtimeModeEvidenceErrors(raw);
    if (requireLiveEvidence) {
      if (raw.privacy !== PRIVACY_MARKER) {
        errors.push(`runtime mode evidence privacy must be ${PRIVACY_MARKER}`);
      }
      const release = raw.release ?? {};
      for (const field of ["deployedCommit", "sourceLocation", "dependencyLocks"]) {
        if (!release[field]) errors.push(`runtime mode evidence release.${field} is required`);
      }
      const generatedAt = Date.parse(raw.generatedAt ?? "");
      if (!Number.isFinite(generatedAt)) {
        errors.push("runtime mode evidence generatedAt must be an ISO timestamp");
      } else if (Date.now() - generatedAt > 24 * 60 * 60 * 1000) {
        errors.push("runtime mode evidence must be generated within the last 24 hours");
      }
      if (!String(raw.writePath?.modeSource ?? "").includes("gcloud run services describe")) {
        errors.push("runtime mode evidence writePath.modeSource must come from gcloud service/revision inspection");
      }
      const services = raw.writePath?.services ?? [];
      for (const service of services) {
        if (!service?.latestReadyRevision) {
          errors.push(`runtime mode evidence service ${service?.service ?? "<unknown>"} is missing latestReadyRevision`);
        }
        if (service?.signalRequired !== true) {
          errors.push(`runtime mode evidence service ${service?.service ?? "<unknown>"} is not signalRequired`);
        }
      }
      const collections = raw.collections ?? {};
      for (const [name, summary] of Object.entries(collections)) {
        if (summary?.truncated === true) {
          errors.push(`runtime mode evidence ${name}.truncated must be false before live execute`);
        }
        const counts = summary.counts ?? summary.classifications ?? {};
        for (const field of BLOCKERS) {
          if (Number(counts[field] ?? 0) !== 0) {
            errors.push(`runtime mode evidence ${name}.${field} must be 0 before live execute`);
          }
        }
      }
    }
    return errors;
  } catch (error) {
    return [`runtime mode evidence is not readable JSON: ${error.message}`];
  }
}

function emptyPrivateExport() {
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    privacy: "private_export_contains_document_values_do_not_commit",
    blockedRecords: [],
    predeleteRecords: [],
  };
}

function pushExportRecord(records, collection, index, classification, data, extra = {}) {
  records.push({
    collection: collection.id,
    collectionGroup: collection.collectionGroup,
    index,
    classification,
    data,
    ...extra,
  });
}

function summarizeFixture(fixture, { execute = false, capturePredelete = false, privateExport = undefined } = {}) {
  const collections = {};
  let eligible = 0;
  let blocked = 0;
  for (const collection of COLLECTIONS) {
    const documents = fixture[collection.id] ?? [];
    const summary = summarizeDocuments(documents, collection);
    const counts = summary.counts;
    const collectionEligible = [...DELETABLE].reduce((total, field) => total + (counts[field] ?? 0), 0);
    const collectionBlocked = [...BLOCKERS].reduce((total, field) => total + (counts[field] ?? 0), 0);
    eligible += collectionEligible;
    blocked += collectionBlocked;
    documents.forEach((document, index) => {
      const classification = classifyGatewayDocument(document, collection.plaintextFields);
      if (privateExport && BLOCKERS.has(classification)) {
        pushExportRecord(privateExport.blockedRecords, collection, index, classification, document);
      }
      if (privateExport && (execute || capturePredelete) && DELETABLE.has(classification)) {
        pushExportRecord(privateExport.predeleteRecords, collection, index, classification, document);
      }
    });
    collections[collection.id] = {
      ...summary,
      eligible: collectionEligible,
      deleted: execute ? collectionEligible : 0,
      dryRun: !execute,
    };
  }
  return { collections, eligible, blocked };
}

function requireFirebaseAdmin() {
  return require(path.join(repoRoot, "functions/node_modules/firebase-admin"));
}

function initializeFirestore({ projectId }) {
  const admin = requireFirebaseAdmin();
  if (admin.apps.length === 0) admin.initializeApp(projectId ? { projectId } : undefined);
  return { admin, db: admin.firestore() };
}

async function drainCollection(db, admin, collection, options) {
  const counts = {};
  let scanned = 0;
  let blocked = 0;
  let cursor;
  let truncated = false;
  while (scanned <= options.maxDocsPerCollection) {
    const remainingWithSentinel = options.maxDocsPerCollection - scanned + 1;
    if (remainingWithSentinel <= 0) {
      truncated = true;
      break;
    }
    const queryLimit = Math.min(options.pageSize, remainingWithSentinel);
    let query = db.collectionGroup(collection.collectionGroup).orderBy(admin.firestore.FieldPath.documentId()).limit(queryLimit);
    if (cursor) query = query.startAfter(cursor);
    const snap = await query.get();
    if (snap.empty) break;
    for (const doc of snap.docs) {
      if (scanned >= options.maxDocsPerCollection) {
        truncated = true;
        break;
      }
      const classification = classifyGatewayDocument(doc.data(), collection.plaintextFields);
      counts[classification] = (counts[classification] ?? 0) + 1;
      scanned += 1;
      if (BLOCKERS.has(classification)) blocked += 1;
      if (options.privateExport && BLOCKERS.has(classification)) {
        options.privateExport.blockedRecords.push({
          collection: collection.id,
          collectionGroup: collection.collectionGroup,
          path: doc.ref.path,
          classification,
          data: doc.data(),
        });
      }
      if (options.privateExport && options.capturePredelete && DELETABLE.has(classification)) {
        const updateTime = doc.updateTime;
        options.privateExport.predeleteRecords.push({
          collection: collection.id,
          collectionGroup: collection.collectionGroup,
          path: doc.ref.path,
          classification,
          updateTime: updateTime?.toDate ? updateTime.toDate().toISOString() : undefined,
          data: doc.data(),
        });
        if (options.deleteCandidates) {
          options.deleteCandidates.push({
            collection: collection.id,
            path: doc.ref.path,
            updateTime,
          });
        }
      }
    }
    if (truncated) break;
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < queryLimit) break;
  }
  return {
    collectionGroup: collection.collectionGroup,
    scanned,
    sampleLimit: options.maxDocsPerCollection,
    truncated,
    counts,
    eligible: [...DELETABLE].reduce((total, field) => total + (counts[field] ?? 0), 0),
    blocked,
    deleted: 0,
    dryRun: true,
  };
}

async function drainLive(options) {
  const { admin, db } = initializeFirestore(options);
  const collections = {};
  let blocked = 0;
  for (const collection of COLLECTIONS) {
    const summary = await drainCollection(db, admin, collection, options);
    blocked += summary.blocked;
    collections[collection.id] = summary;
  }
  return { collections, blocked };
}

async function previewDrain(options) {
  const previewOptions = { ...options, execute: false };
  return options.fixture
    ? summarizeFixture(JSON.parse(fs.readFileSync(options.fixture, "utf8")), previewOptions)
    : await drainLive(previewOptions);
}

function markExecuted(preview) {
  const collections = {};
  for (const [name, summary] of Object.entries(preview.collections)) {
    collections[name] = {
      ...summary,
      deleted: summary.eligible,
      dryRun: false,
    };
  }
  return {
    collections,
    eligible: preview.eligible,
    blocked: preview.blocked,
  };
}

function truncatedCollections(preview) {
  return Object.entries(preview.collections ?? {})
    .filter(([, summary]) => summary?.truncated === true)
    .map(([name]) => name);
}

async function deleteCapturedCandidates(options, deleteCandidates) {
  if (deleteCandidates.length === 0) return;
  const { db } = initializeFirestore(options);
  const writer = db.bulkWriter();
  writer.onWriteError(() => false);
  for (const candidate of deleteCandidates) {
    const precondition = candidate.updateTime ? { lastUpdateTime: candidate.updateTime } : undefined;
    writer.delete(db.doc(candidate.path), precondition);
  }
  await writer.close();
}

function parseArgs(argv) {
  const options = {
    execute: false,
    confirmation: undefined,
    runtimeModeEvidence: undefined,
    output: undefined,
    fixture: undefined,
    projectId: undefined,
    pageSize: 500,
    maxDocsPerCollection: 50000,
    quarantineOutput: undefined,
    predeleteExport: undefined,
    liveProductionAcknowledgement: undefined,
    selfTest: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[index];
    };
    if (arg === "--self-test") options.selfTest = true;
    else if (arg === "--execute") options.execute = true;
    else if (arg === "--confirm") options.confirmation = next();
    else if (arg === "--runtime-mode-evidence") options.runtimeModeEvidence = next();
    else if (arg === "--output") options.output = next();
    else if (arg === "--fixture") options.fixture = next();
    else if (arg === "--project-id") options.projectId = next();
    else if (arg === "--quarantine-output") options.quarantineOutput = next();
    else if (arg === "--predelete-export") options.predeleteExport = next();
    else if (arg === "--live-production-acknowledgement") options.liveProductionAcknowledgement = next();
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (options.execute) {
    if (options.confirmation !== EXECUTE_CONFIRMATION) {
      throw new Error(`--execute requires --confirm ${EXECUTE_CONFIRMATION}`);
    }
    if (!options.fixture) {
      if (!options.projectId) {
        throw new Error("--execute against live Firestore requires --project-id");
      }
      const expectedAck = `${LIVE_PRODUCTION_ACK_PREFIX}${options.projectId}`;
      if (options.liveProductionAcknowledgement !== expectedAck) {
        throw new Error(`--execute against live Firestore requires --live-production-acknowledgement ${expectedAck}`);
      }
    }
    const errors = validateRuntimeModeEvidence(options.runtimeModeEvidence, { requireLiveEvidence: !options.fixture });
    if (errors.length > 0) throw new Error(errors.join("; "));
    if (!options.predeleteExport) {
      throw new Error("--execute requires --predelete-export so known legacy records are exported before deletion");
    }
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

function writePrivateExport(privateExport, output) {
  if (!output) return;
  const body = `${JSON.stringify(privateExport, null, 2)}\n`;
  fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
  fs.writeFileSync(output, body, { encoding: "utf8", mode: 0o600 });
}

function runSelfTest() {
  const fixture = {
    events: [
      { signalEnvelope: validGatewaySignalEnvelope() },
      { relayEnvelope: { ciphertext: "x" } },
      { text: "legacy cleartext" },
      { __unreadable: true },
      { schemaVersion: 4 },
    ],
  };
  const summary = summarizeFixture(fixture);
  assert.equal(summary.eligible, 2);
  assert.equal(summary.blocked, 2);
  assert.equal(summary.collections.events.deleted, 0);
  assert.equal(classifyGatewayDocument({ schemaVersion: 4 }, ["text"]), "unknownSchema");
  assert.equal(classifyGatewayDocument({ __unreadable: true }, ["text"]), "unreadable");
  const privateExport = emptyPrivateExport();
  summarizeFixture(fixture, { privateExport });
  assert.equal(privateExport.blockedRecords.length, 2);
  assert.equal(privateExport.predeleteRecords.length, 0);
  const runtimeErrors = runtimeModeEvidenceErrors({
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
  });
  assert.deepEqual(runtimeErrors, []);
}

async function main(argv = process.argv.slice(2)) {
  const options = parseArgs(argv);
  if (options.selfTest) {
    runSelfTest();
    console.log("PASS: Hermes Gateway legacy drain self-test passed");
    return;
  }
  let result;
  if (options.execute) {
    const privateExport = emptyPrivateExport();
    const deleteCandidates = [];
    const preview = await previewDrain({ ...options, privateExport, capturePredelete: true, deleteCandidates });
    if (privateExport.blockedRecords.length > 0 && options.quarantineOutput) {
      writePrivateExport(privateExport, options.quarantineOutput);
    }
    const truncated = truncatedCollections(preview);
    if (truncated.length > 0) {
      throw new Error(
        `refusing --execute because the scan reached maxDocsPerCollection before exhausting collection group(s): ${truncated.join(", ")}`,
      );
    }
    if (preview.blocked > 0) {
      throw new Error(
        "refusing --execute because unreadable/malformed/unknown records are present; preserve them with --quarantine-output and investigate manually",
      );
    }
    writePrivateExport(privateExport, options.predeleteExport);
    if (!options.fixture) {
      await deleteCapturedCandidates(options, deleteCandidates);
    }
    result = markExecuted(preview);
  } else {
    result = options.fixture
      ? summarizeFixture(JSON.parse(fs.readFileSync(options.fixture, "utf8")), options)
      : await drainLive(options);
  }
  writeEvidence(
    {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      privacy: PRIVACY_MARKER,
      mode: options.execute ? "execute" : "dry_run",
      safety: {
        executeConfirmation: options.execute ? EXECUTE_CONFIRMATION : "not_requested",
        runtimeModeEvidence: options.runtimeModeEvidence ?? null,
        quarantineOutput: options.quarantineOutput ?? null,
        predeleteExport: options.predeleteExport ?? null,
        liveProductionAcknowledgement: options.liveProductionAcknowledgement ?? null,
      },
      collections: result.collections,
    },
    options.output,
  );
}

module.exports = {
  runtimeModeEvidenceErrors,
  validateRuntimeModeEvidence,
  summarizeFixture,
  drainCollection,
  DELETABLE,
  BLOCKERS,
  parseArgs,
  main,
};

if (require.main === module) {
  main().catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}
