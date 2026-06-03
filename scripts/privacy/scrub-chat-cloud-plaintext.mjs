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
];

const MISSION_EVENT_FIELDS = ["title", "message", "fullMessage", "toolName", "artifactPath", "changedFilePath"];

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
not delete documents or sealed payloads.`);
}
