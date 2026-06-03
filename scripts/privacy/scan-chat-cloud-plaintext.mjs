#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "../..");

const failures = [];

function readRel(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function fail(message) {
  failures.push(message);
}

function assertIncludes(relativePath, needle, note) {
  const text = readRel(relativePath);
  if (!text.includes(needle)) {
    fail(`${relativePath}: missing ${note ?? JSON.stringify(needle)}`);
  }
}

function assertNotIncludes(relativePath, needle, note) {
  const text = readRel(relativePath);
  if (text.includes(needle)) {
    fail(`${relativePath}: contains forbidden ${note ?? JSON.stringify(needle)}`);
  }
}

function assertSectionIncludes(relativePath, startNeedle, endNeedle, needle, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (!section.includes(needle)) {
    fail(`${relativePath}: ${note ?? "section assertion failed"}`);
  }
}

function assertSectionNotIncludes(relativePath, startNeedle, endNeedle, needle, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (section.includes(needle)) {
    fail(`${relativePath}: ${note ?? `section contains forbidden ${JSON.stringify(needle)}`}`);
  }
}

function sectionBetween(relativePath, startNeedle, endNeedle) {
  const text = readRel(relativePath);
  const start = text.indexOf(startNeedle);
  if (start < 0) {
    fail(`${relativePath}: missing section start ${JSON.stringify(startNeedle)}`);
    return "";
  }
  const end = text.indexOf(endNeedle, start + startNeedle.length);
  if (end < 0) {
    fail(`${relativePath}: missing section end ${JSON.stringify(endNeedle)}`);
    return text.slice(start);
  }
  return text.slice(start, end);
}

function assertRulesRejectFields(sectionName, fields) {
  const rules = readRel("firestore.rules");
  const start = rules.indexOf(sectionName);
  if (start < 0) {
    fail(`firestore.rules: missing ${sectionName}`);
    return;
  }
  const section = rules.slice(start, Math.min(rules.length, start + 7000));
  for (const field of fields) {
    if (!section.includes(`"${field}"`)) {
      fail(`firestore.rules: ${sectionName} does not mention plaintext field ${field}`);
    }
  }
  if (!section.includes("!request.resource.data.keys().hasAny")) {
    fail(`firestore.rules: ${sectionName} does not reject plaintext fields with hasAny`);
  }
}

function assertRulesAllowlistExcludes(sectionName, fields, endNeedle = "allow read:") {
  const rules = readRel("firestore.rules");
  const start = rules.indexOf(sectionName);
  if (start < 0) {
    fail(`firestore.rules: missing ${sectionName}`);
    return;
  }
  const end = rules.indexOf(endNeedle, start + sectionName.length);
  const section = end < 0 ? rules.slice(start, Math.min(rules.length, start + 4500)) : rules.slice(start, end);
  for (const field of fields) {
    if (section.includes(`"${field}"`)) {
      fail(`firestore.rules: ${sectionName} allowlist still contains plaintext field ${field}`);
    }
  }
}

function assertRegistryEndToEnd() {
  const registry = JSON.parse(readRel("packages/data-domains/registry.json"));
  const domain = registry.domains.find((entry) => entry.id === "conversations_chat");
  if (!domain) {
    fail("packages/data-domains/registry.json: missing conversations_chat domain");
    return;
  }
  if (domain.encryptionTier !== "end_to_end") {
    fail(`packages/data-domains/registry.json: conversations_chat tier is ${domain.encryptionTier}`);
  }
  const requiredPaths = [
    "conversations",
    "chat_threads",
    "mobile_assistant_chats",
    "cli_sessions",
    "cli_agent_mission_requests",
    "text_snippets",
  ];
  for (const requiredPath of requiredPaths) {
    if (!domain.firestorePaths.includes(requiredPath)) {
      fail(`packages/data-domains/registry.json: conversations_chat missing ${requiredPath}`);
    }
  }
}

assertRegistryEndToEnd();

assertRulesRejectFields("function validConversationMirror()", [
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
]);

assertIncludes("firestore.rules", "function chatThreadHasPlaintextContent()", "chat thread plaintext-content helper");
for (const field of ["messages", "title", "preview"]) {
  assertIncludes("firestore.rules", `"${field}"`, `chat thread plaintext field ${field}`);
}

assertRulesAllowlistExcludes("function validMobileAssistantChatMirror()", [
  "title",
  "preview",
  "messages",
  "modelName",
  "customTitle",
]);

assertRulesAllowlistExcludes("function validCliSessionMirror()", [
  "title",
  "preview",
  "messages",
  "modelName",
  "workspaceLabel",
  "resumeHandle",
  "customTitle",
]);

assertRulesRejectFields("function validCliAgentMissionRequest()", [
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
]);

assertRulesRejectFields("match /events/{eventId}", [
  "title",
  "message",
  "fullMessage",
  "toolName",
  "artifactPath",
  "changedFilePath",
]);

assertRulesAllowlistExcludes("match /users/{userId}/agent_notification_replies", ["replyText"], "allow update:");

assertIncludes(
  "AgentLens/Services/CloudSync/ConversationSyncService.swift",
  '"sealedPayload": try ConversationCloudSealer.seal',
  "conversation sealed payload write",
);
assertIncludes(
  "AgentLens/Services/CloudSync/ConversationSyncService.swift",
  '"contentSealed": true',
  "conversation contentSealed true",
);

for (const field of ["title", "preview", "messages"]) {
  assertIncludes(
    "AgentLens/Services/CloudSync/ChatThreadSyncService.swift",
    `data["${field}"] = FieldValue.delete()`,
    `chat thread deletes top-level ${field}`,
  );
}
assertIncludes(
  "AgentLens/Services/CloudSync/ChatThreadSyncService.swift",
  "CloudVaultCrypto.sealPayload",
  "chat thread Cloud Vault sealing",
);

assertIncludes(
  "AgentLens/Services/CloudSync/CLIAgentSessionMirror.swift",
  "CLIAgentSessionCodec.encodeSealed",
  "CLI session writer uses sealed codec",
);
assertSectionNotIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift",
  "public static func encodeSealed(",
  "public static func encodeMessage",
  '"title"',
  "CLI sealed payload top-level contains title",
);
for (const field of ['"preview"', '"messages"', '"modelName"', '"workspaceLabel"', '"resumeHandle"', '"customTitle"']) {
  assertSectionNotIncludes(
    "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift",
    "public static func encodeSealed(",
    "public static func encodeMessage",
    field,
    `CLI sealed payload top-level contains ${field}`,
  );
}

assertSectionIncludes(
  "OpenBurnBarMobile/Services/MobileChatHistoryStore.swift",
  "func upsert(_ thread: MobileChatThread)",
  "static func encodeThreadForCloud",
  '"contentSealed": true',
  "mobile assistant writer contentSealed true",
);
assertSectionIncludes(
  "OpenBurnBarMobile/Services/MobileChatHistoryStore.swift",
  "func upsert(_ thread: MobileChatThread)",
  "static func encodeThreadForCloud",
  '"sealedPayload": CloudVaultCrypto.sealedPayloadDictionary',
  "mobile assistant writer sealed payload",
);
for (const field of ['"title"', '"preview"', '"messages"', '"modelName"', '"customTitle"']) {
  assertSectionNotIncludes(
    "OpenBurnBarMobile/Services/MobileChatHistoryStore.swift",
    "func upsert(_ thread: MobileChatThread)",
    "static func encodeThreadForCloud",
    field,
    `mobile assistant writer top-level contains ${field}`,
  );
}

for (const field of [
  "title",
  "prompt",
  "targetProject",
  "liveSummary",
  "resultPreview",
  "errorMessage",
  "approvalTitle",
  "approvalMessage",
  "personaScopeJSON",
]) {
  assertIncludes(
    "OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift",
    `"${field}"`,
    `mobile mission sealer handles ${field}`,
  );
}
assertIncludes(
  "OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift",
  "payload.removeValue(forKey: key)",
  "mobile mission removes private top-level fields",
);
assertIncludes(
  "OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift",
  "sealedPayload",
  "mobile mission sealed payload",
);

assertIncludes(
  "AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift",
  "static func sealedEvent",
  "Mac mission sealed event helper",
);
assertIncludes(
  "AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift",
  "sealed.removeValue(forKey: key)",
  "Mac mission removes private event fields",
);

assertIncludes(
  "functions/src/agentNotifications.ts",
  'const GENERIC_PREVIEW = "OpenBurnBar has a new agent reply."',
  "generic notification preview",
);
assertNotIncludes("functions/src/agentNotifications.ts", "createHash", "notification content hashing");
assertNotIncludes("functions/src/agentNotifications.ts", "truncatePreview", "notification text preview truncation");
assertNotIncludes("functions/src/agentNotifications.ts", "messageText", "notification message text event id input");
assertNotIncludes("functions/src/agentNotifications.ts", "preview: reply.text", "notification plaintext preview");
assertIncludes(
  "functions/src/callables/agentNotifications.ts",
  "sealedReplyPayload",
  "notification reply sealed payload",
);
assertNotIncludes("functions/src/callables/agentNotifications.ts", "replyText", "notification reply plaintext field");

assertIncludes(
  "AgentLens/Services/ICloudSessionMirrorService.swift",
  "rawMirrorDisabledMessage",
  "iCloud raw mirror disabled message",
);
assertIncludes(
  "AgentLens/Services/ICloudSessionMirrorService.swift",
  "return 0",
  "iCloud mirror byte estimator returns zero",
);
assertIncludes(
  "AgentLens/Services/ICloudSessionMirrorService.swift",
  "rawMirrorDisabled",
  "iCloud raw mirror disabled error",
);

if (failures.length) {
  console.error("Cloud plaintext hardening scan failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Cloud plaintext hardening scan passed.");
