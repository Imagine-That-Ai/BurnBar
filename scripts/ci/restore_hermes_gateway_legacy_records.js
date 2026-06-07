#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { COLLECTIONS, classifyGatewayDocument } = require("./write_hermes_gateway_migration_drain_evidence.js");

const repoRoot = path.resolve(__dirname, "..", "..");
const PRIVATE_EXPORT_MARKER = "private_export_contains_document_values_do_not_commit";
const EXECUTE_CONFIRMATION = "restore-hermes-gateway-predelete-export";
const LIVE_PRODUCTION_ACK_PREFIX = "restore-production-hermes-gateway-records-in-";
const RESTORABLE_CLASSIFICATIONS = new Set(["knownLegacyRelay", "knownLegacyRatchet", "knownLegacyPlaintext"]);
const COLLECTION_BY_ID = new Map(COLLECTIONS.map((collection) => [collection.id, collection]));
const COLLECTION_BY_GROUP = new Map(COLLECTIONS.map((collection) => [collection.collectionGroup, collection]));

function requireFirebaseAdmin() {
  return require(path.join(repoRoot, "functions/node_modules/firebase-admin"));
}

function initializeFirestore({ projectId }) {
  const admin = requireFirebaseAdmin();
  if (admin.apps.length === 0) admin.initializeApp({ projectId });
  return { db: admin.firestore() };
}

function parseArgs(argv) {
  const options = {
    exportPath: undefined,
    projectId: undefined,
    execute: false,
    confirmation: undefined,
    liveProductionAcknowledgement: undefined,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      index += 1;
      if (index >= argv.length) throw new Error(`${arg} requires a value`);
      return argv[index];
    };
    if (arg === "--export") options.exportPath = next();
    else if (arg === "--project-id") options.projectId = next();
    else if (arg === "--execute") options.execute = true;
    else if (arg === "--confirm") options.confirmation = next();
    else if (arg === "--live-production-acknowledgement") options.liveProductionAcknowledgement = next();
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (!options.exportPath) throw new Error("--export is required");
  if (!options.projectId) throw new Error("--project-id is required");
  if (options.execute) {
    if (options.confirmation !== EXECUTE_CONFIRMATION) {
      throw new Error(`--execute requires --confirm ${EXECUTE_CONFIRMATION}`);
    }
    const expectedAck = `${LIVE_PRODUCTION_ACK_PREFIX}${options.projectId}`;
    if (options.liveProductionAcknowledgement !== expectedAck) {
      throw new Error(`--execute requires --live-production-acknowledgement ${expectedAck}`);
    }
  }
  return options;
}

function loadPredeleteExport(exportPath) {
  const data = JSON.parse(fs.readFileSync(exportPath, "utf8"));
  if (data.privacy !== PRIVATE_EXPORT_MARKER) {
    throw new Error(`private export privacy marker must be ${PRIVATE_EXPORT_MARKER}`);
  }
  const records = data.predeleteRecords ?? [];
  if (!Array.isArray(records) || records.length === 0) {
    throw new Error("private export has no predeleteRecords to restore");
  }
  for (const [index, record] of records.entries()) {
    validateRestorableRecord(record, index);
  }
  return data;
}

function collectionGroupFromDocumentPath(documentPath) {
  const segments = String(documentPath).split("/");
  if (segments.some((segment) => segment.length === 0) || segments.length < 2 || segments.length % 2 !== 0) {
    return undefined;
  }
  return segments[segments.length - 2];
}

function validateRestorableRecord(record, index) {
  if (!record?.path || typeof record.path !== "string") {
    throw new Error(`predeleteRecords[${index}].path is required`);
  }
  const collectionGroup = collectionGroupFromDocumentPath(record.path);
  const collection = COLLECTION_BY_GROUP.get(collectionGroup);
  if (!collection) {
    throw new Error(`predeleteRecords[${index}].path is not an allowed Hermes Gateway document path`);
  }
  if (record.collection && record.collection !== collection.id) {
    throw new Error(`predeleteRecords[${index}].collection does not match ${collection.id}`);
  }
  if (record.collectionGroup && record.collectionGroup !== collection.collectionGroup) {
    throw new Error(`predeleteRecords[${index}].collectionGroup does not match ${collection.collectionGroup}`);
  }
  if (!COLLECTION_BY_ID.has(record.collection)) {
    throw new Error(`predeleteRecords[${index}].collection is required`);
  }
  if (!RESTORABLE_CLASSIFICATIONS.has(record.classification)) {
    throw new Error(`predeleteRecords[${index}].classification must be a known legacy classification`);
  }
  if (!record?.data || typeof record.data !== "object" || Array.isArray(record.data)) {
    throw new Error(`predeleteRecords[${index}].data must be an object`);
  }
  const actual = classifyGatewayDocument(record.data, collection.plaintextFields);
  if (actual !== record.classification) {
    throw new Error(
      `predeleteRecords[${index}].data classification mismatch: ${actual} != ${record.classification}`,
    );
  }
}

function queueRestoreRecord(writer, db, record) {
  writer.create(db.doc(record.path), record.data);
}

async function restore(options) {
  const data = loadPredeleteExport(options.exportPath);
  const records = data.predeleteRecords;
  if (!options.execute) {
    const collections = new Map();
    for (const record of records) {
      const key = record.collection ?? record.collectionGroup ?? "unknown";
      collections.set(key, (collections.get(key) ?? 0) + 1);
    }
    console.log(
      JSON.stringify(
        {
          mode: "dry_run",
          wouldRestore: records.length,
          collections: Object.fromEntries(collections),
          executeCommandRequires: {
            confirm: EXECUTE_CONFIRMATION,
            liveProductionAcknowledgement: `${LIVE_PRODUCTION_ACK_PREFIX}${options.projectId}`,
          },
        },
        null,
        2,
      ),
    );
    return;
  }

  const { db } = initializeFirestore(options);
  const writer = db.bulkWriter();
  for (const record of records) {
    queueRestoreRecord(writer, db, record);
  }
  await writer.close();
  console.log(`RESTORED: ${records.length} Hermes Gateway record(s) from private pre-delete export`);
}

if (require.main === module) {
  restore(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(`FAIL: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = { parseArgs, loadPredeleteExport, validateRestorableRecord, queueRestoreRecord };
