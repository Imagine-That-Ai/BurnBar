#!/usr/bin/env node
import { createRequire } from "node:module";

const requireFromFunctions = createRequire(new URL("../../functions/package.json", import.meta.url));

let initializeApp;
let getApps;
let getFirestore;
let FieldValue;

try {
  ({ initializeApp, getApps } = requireFromFunctions("firebase-admin/app"));
  ({ getFirestore, FieldValue } = requireFromFunctions("firebase-admin/firestore"));
} catch (error) {
  console.error("Unable to load firebase-admin from functions/node_modules.");
  console.error("Run `npm --prefix functions install` first, then retry.");
  console.error(String(error));
  process.exit(127);
}

const COLLECTIONS = [
  {
    name: "conversations",
    fields: [
      "projectName",
      "keyFiles",
      "keyCommands",
      "keyTools",
      "inferredTaskTitle",
      "lastAssistantMessage",
      "workingDirectory",
      "summary",
      "summaryTitle",
      "summaryProvider",
      "summaryModel",
    ],
  },
  {
    name: "chat_threads",
    fields: ["title", "preview", "messages"],
  },
  {
    name: "mobile_assistant_chats",
    fields: ["title", "preview", "messages", "modelName", "customTitle"],
  },
  {
    name: "cli_sessions",
    fields: ["title", "preview", "messages", "modelName", "workspaceLabel", "resumeHandle", "customTitle"],
  },
  {
    name: "cli_agent_mission_requests",
    fields: [
      "title",
      "prompt",
      "targetProject",
      "approvalTitle",
      "approvalMessage",
      "liveSummary",
      "events",
      "resultPreview",
      "errorMessage",
      "personaScopeJSON",
    ],
  },
  {
    name: "agent_notification_replies",
    fields: ["replyText"],
  },
  {
    name: "session_logs",
    fields: ["projectName", "workingDirectory", "body", "payloadCiphertext", "ciphertext", "data", "text", "title", "snippet", "terms"],
  },
  {
    name: "cloud_search_documents",
    fields: ["projectName", "workingDirectory", "title", "snippet", "body", "text"],
  },
  {
    name: "cloud_search_chunks",
    fields: ["projectName", "workingDirectory", "title", "snippet", "body", "text"],
  },
  {
    name: "cloud_search_postings",
    fields: ["projectName", "workingDirectory", "title", "snippet", "body", "text"],
  },
  // Project memory snapshots: the project name now lives only inside the sealed
  // snapshot; the legacy top-level project-identity duplicates are deleted. Doc
  // ids are opaque vault-keyed HMACs (the device rewrites them on next sync).
  {
    name: "project_memory_snapshots",
    fields: ["projectDisplayName", "projectSlug"],
  },
  // Saved text snippets: legacy plaintext snippet body fields, superseded by the
  // sealed payload (kept here so a stranded legacy snippet body is scrubbed).
  {
    name: "text_snippets",
    fields: ["text", "body", "content", "title", "preview"],
  },
  // Hosted chat gateway (server-written; E2E migration is a chained goal). The
  // gateway carries readable message text / sender names / file names in
  // transit; the scrubber removes the stored plaintext copies of those fields.
  {
    name: "hermes_gateway_messages",
    fields: ["text", "threadId", "replyToEventId"],
  },
  {
    name: "hermes_gateway_events",
    fields: ["text", "senderDisplayName", "threadId"],
  },
  {
    name: "hermes_gateway_attachments",
    fields: ["fileName"],
  },
  {
    name: "approval_policies",
    fields: ["id", "displayLabel", "fileGlob", "targetProject"],
  },
  {
    name: "rollback_requests",
    fields: ["scopeJSON", "errorMessage"],
  },
  {
    name: "agent_identities",
    fields: ["displayName", "tagline", "personas"],
  },
  {
    name: "subscription_topics",
    fields: ["agentURI", "topicID", "displayName", "description"],
  },
];

// Relay requests + their /chunks subcollections: legacy schema-v1 plaintext
// fields that predate the sealed relay envelope (schemaVersion >= 2). The
// hardened path stores only payloadCiphertext + wrappedKey; any of these
// fields lingering on a legacy row is scrubbed.
const RELAY_REQUEST_COLLECTIONS = ["hermes_relay_requests", "pi_agent_relay_requests"];
const RELAY_REQUEST_FIELDS = ["path", "sessionId", "body", "error", "data", "text"];
const RELAY_CHUNK_FIELDS = ["body", "error", "data", "text"];

const MISSION_EVENT_FIELDS = ["title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath"];
const ROLLBACK_SNAPSHOT_FIELDS = ["actionLabel", "touchedFiles", "macSnapshotPath"];
const SESSION_LOG_CHUNK_FIELDS = [
  "projectName",
  "workingDirectory",
  "body",
  "payloadCiphertext",
  "ciphertext",
  "data",
  "text",
  "title",
  "snippet",
  "terms",
];

const options = parseArgs(process.argv.slice(2));
if (options.help) {
  printHelp();
  process.exit(0);
}
if (!options.allUsers && options.uids.length === 0) {
  printHelp();
  console.error("\nPass at least one --uid <uid>, or --all-users.");
  process.exit(2);
}

if (!getApps().length) {
  initializeApp(options.projectId ? { projectId: options.projectId } : undefined);
}

const db = getFirestore();

const uids = options.allUsers ? await listAllUserIds(db) : options.uids;
let scannedDocs = 0;
let touchedDocs = 0;
let deletedFields = 0;

for (const uid of uids) {
  await scrubUser(uid);
}

console.log(
  `${options.apply ? "Applied" : "Dry run"}: scanned ${scannedDocs} docs, ` +
    `${options.apply ? "updated" : "would update"} ${touchedDocs} docs, ` +
    `${options.apply ? "deleted" : "would delete"} ${deletedFields} legacy plaintext fields.`,
);
if (!options.apply) {
  console.log("Re-run with --apply to delete the listed fields.");
}

async function scrubUser(uid) {
  console.log(`\nUser ${uid}`);
  const userRef = db.collection("users").doc(uid);
  for (const collection of COLLECTIONS) {
    await scrubCollection(userRef.collection(collection.name), collection.fields);
  }

  const missionDocs = await userRef.collection("cli_agent_mission_requests").listDocuments();
  for (const missionRef of missionDocs) {
    await scrubCollection(missionRef.collection("events"), MISSION_EVENT_FIELDS);
  }
  const sessionLogDocs = await userRef.collection("session_logs").listDocuments();
  for (const sessionLogRef of sessionLogDocs) {
    await scrubCollection(sessionLogRef.collection("chunks"), SESSION_LOG_CHUNK_FIELDS);
  }
  const cliSessionDocs = await userRef.collection("cli_sessions").listDocuments();
  for (const cliSessionRef of cliSessionDocs) {
    await scrubCollection(cliSessionRef.collection("snapshots"), ROLLBACK_SNAPSHOT_FIELDS);
  }

  // Relay requests + their /chunks subcollections (Hermes + Pi agent). Scrub the
  // legacy schema-v1 plaintext fields on both the request docs and each chunk.
  for (const relayCollection of RELAY_REQUEST_COLLECTIONS) {
    const relayRequestDocs = await userRef.collection(relayCollection).listDocuments();
    for (const relayRequestRef of relayRequestDocs) {
      await scrubDocument(relayRequestRef, RELAY_REQUEST_FIELDS);
      await scrubCollection(relayRequestRef.collection("chunks"), RELAY_CHUNK_FIELDS);
    }
  }
}

async function scrubCollection(collectionRef, fields) {
  const docs = await collectionRef.listDocuments();
  for (const docRef of docs) {
    await scrubDocument(docRef, fields);
  }
}

async function scrubDocument(docRef, fields) {
  const snap = await docRef.get();
  if (!snap.exists) return;
  scannedDocs += 1;
  const data = snap.data() ?? {};
  const present = fields.filter((field) => Object.prototype.hasOwnProperty.call(data, field));
  if (present.length === 0) return;
  touchedDocs += 1;
  deletedFields += present.length;
  console.log(`- ${docRef.path}: ${present.join(", ")}`);
  if (!options.apply) return;
  const update = Object.fromEntries(present.map((field) => [field, FieldValue.delete()]));
  await docRef.update(update);
}

async function listAllUserIds(firestore) {
  const refs = await firestore.collection("users").listDocuments();
  return refs.map((ref) => ref.id);
}

function parseArgs(argv) {
  const parsed = {
    apply: false,
    allUsers: false,
    help: false,
    projectId: undefined,
    uids: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    switch (arg) {
      case "--apply":
        parsed.apply = true;
        break;
      case "--dry-run":
        parsed.apply = false;
        break;
      case "--all-users":
        parsed.allUsers = true;
        break;
      case "--uid":
        index += 1;
        if (!argv[index]) throw new Error("--uid requires a value");
        parsed.uids.push(argv[index]);
        break;
      case "--project":
      case "--project-id":
        index += 1;
        if (!argv[index]) throw new Error(`${arg} requires a value`);
        parsed.projectId = argv[index];
        break;
      case "--help":
      case "-h":
        parsed.help = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return parsed;
}

function printHelp() {
  console.log(`Usage:
  node scripts/privacy/scrub-chat-cloud-plaintext.mjs --uid <uid> [--project <id>]
  node scripts/privacy/scrub-chat-cloud-plaintext.mjs --all-users [--project <id>]
  node scripts/privacy/scrub-chat-cloud-plaintext.mjs --uid <uid> --apply

Defaults to dry-run. Uses firebase-admin Application Default Credentials or
GOOGLE_APPLICATION_CREDENTIALS. Deletes only legacy plaintext fields; it does
not delete documents or sealed payloads. Covers chat/session-log collections,
	project_memory_snapshots (projectDisplayName/projectSlug), text_snippets,
	Hermes Square sealed-only surfaces (approval policies, rollback requests,
	agent identities, subscription topics, CLI rollback snapshots),
	hermes/pi_agent relay requests + chunks, and the hosted chat gateway
	(hermes_gateway_messages/events/attachments).`);
  }
