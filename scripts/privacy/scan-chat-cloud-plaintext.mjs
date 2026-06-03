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

// SEMANTIC allowlist check: a sensitive rules helper/block must positively
// constrain the WHOLE key set with `keys().hasOnly([...])`, not merely deny a
// handful of known plaintext fields with `!hasAny`. A pure denylist drifts open
// the moment a new plaintext field is added; an allowlist fails closed. This
// closes the "allowlist drift" gap the recon flagged.
function assertRulesSectionHasOnly(sectionName, note, span = 7000) {
  const rules = readRel("firestore.rules");
  const start = rules.indexOf(sectionName);
  if (start < 0) {
    fail(`firestore.rules: missing ${sectionName}`);
    return;
  }
  const section = rules.slice(start, Math.min(rules.length, start + span));
  if (!section.includes("request.resource.data.keys().hasOnly([")) {
    fail(`firestore.rules: ${note ?? `${sectionName} lacks a keys().hasOnly([ allowlist`}`);
  }
}

// Assert a match block bounded by its own `match /…` start and the next `match `
// denies a client write entirely (`allow write: if false`). Used for
// server-only-writer collections whose honest posture this pass is "no client
// plaintext write path" (e.g. the hosted chat gateway, server-written today; its
// end-to-end migration is a separately chained goal).
function assertRulesBlockDeniesClientWrite(matchNeedle, note) {
  const rules = readRel("firestore.rules");
  const start = rules.indexOf(matchNeedle);
  if (start < 0) {
    fail(`firestore.rules: missing ${matchNeedle}`);
    return;
  }
  const next = rules.indexOf("    match /", start + matchNeedle.length);
  const block = rules.slice(start, next < 0 ? rules.length : next);
  if (!block.includes("allow write: if false")) {
    fail(`firestore.rules: ${note ?? `${matchNeedle} must deny client writes (allow write: if false)`}`);
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
  const sessionLogs = registry.domains.find((entry) => entry.id === "session_logs");
  if (!sessionLogs) {
    fail("packages/data-domains/registry.json: missing session_logs domain");
    return;
  }
  for (const forbidden of ["project", "working directory", "path text"]) {
    if (sessionLogs.serverSees.some((value) => value.toLowerCase().includes(forbidden))) {
      fail(`packages/data-domains/registry.json: session_logs serverSees includes ${forbidden}`);
    }
  }
  if (!sessionLogs.deviceOnly.some((value) => value.toLowerCase().includes("project/path text"))) {
    fail("packages/data-domains/registry.json: session_logs deviceOnly missing project/path text");
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

for (const field of ["title", "snippet", "terms", "projectName", "workingDirectory"]) {
  assertSectionIncludes(
    "firestore.rules",
    "function ownerWritableSessionLogManifest(",
    "function validSessionLogFacetCount(",
    `!("${field}" in request.resource.data)`,
    `session-log manifest rejects ${field}`,
  );
  assertSectionIncludes(
    "firestore.rules",
    "function ownerWritableSessionLogChunk(",
    "function validCloudHexDigest(",
    `!("${field}" in request.resource.data)`,
    `session-log chunk rejects ${field}`,
  );
}
assertRulesAllowlistExcludes("match /users/{userId}/cloud_search_documents/{documentId}", ["projectName"], "allow delete:");
assertRulesAllowlistExcludes("match /users/{userId}/cloud_search_chunks/{chunkId}", ["projectName"], "allow delete:");
assertRulesAllowlistExcludes("match /users/{userId}/cloud_search_postings/{postingId}", ["projectName"], "allow delete:");

assertSectionIncludes(
  "firestore.rules",
  "function relayRequestWrite(",
  "function relayChunkWrite(",
  "request.resource.data.schemaVersion >= 2",
  "hosted relay requests require encrypted schema",
);
for (const field of ["path", "sessionId", "body", "error"]) {
  assertSectionIncludes(
    "firestore.rules",
    "function relayRequestWrite(",
    "function relayChunkWrite(",
    `!("${field}" in request.resource.data)`,
    `hosted relay request rejects plaintext ${field}`,
  );
}
assertSectionIncludes(
  "firestore.rules",
  "function relayRequestWrite(",
  "function relayChunkWrite(",
  "request.resource.data.payloadCiphertext is string",
  "hosted relay request requires payload ciphertext",
);
assertSectionNotIncludes(
  "firestore.rules",
  "function relayRequestWrite(",
  "function relayChunkWrite(",
  "request.resource.data.schemaVersion < 2",
  "hosted relay request legacy plaintext schema branch",
);
assertSectionIncludes(
  "firestore.rules",
  "function relayChunkWrite(",
  "function hermesGatewayDestinationWrite(",
  "request.resource.data.schemaVersion >= 2",
  "hosted relay chunks require encrypted schema",
);
for (const field of ["data", "text", "error"]) {
  assertSectionIncludes(
    "firestore.rules",
    "function relayChunkWrite(",
    "function hermesGatewayDestinationWrite(",
    `!("${field}" in request.resource.data)`,
    `hosted relay chunk rejects plaintext ${field}`,
  );
}
assertSectionNotIncludes(
  "firestore.rules",
  "function relayChunkWrite(",
  "function hermesGatewayDestinationWrite(",
  "request.resource.data.schemaVersion < 2",
  "hosted relay chunk legacy plaintext schema branch",
);

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
assertIncludes(
  "AgentLens/Services/CloudSync/DownloadSyncService.swift",
  'guard data["contentSealed"] as? Bool == true,',
  "conversation download requires contentSealed",
);
for (const field of [
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
]) {
  assertSectionNotIncludes(
    "AgentLens/Services/CloudSync/DownloadSyncService.swift",
    "private func downloadRemoteConversations(",
    "return insertedIds",
    `data["${field}"]`,
    `conversation download plaintext fallback for ${field}`,
  );
}
assertNotIncludes(
  "AgentLens/Services/CloudSync/DownloadSyncService.swift",
  "downloadRemoteSessionLogBodies",
  "legacy Firestore session-log body auto-hydration",
);
assertNotIncludes(
  "AgentLens/Services/CloudSync/DownloadSyncService.swift",
  'collection("chunks")',
  "legacy Firestore session-log chunk body reader",
);
assertIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "func downloadEncryptedBody(storagePath: String) async throws -> Data",
  "encrypted session body download client",
);
assertIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "Legacy Firestore chunk bodies are intentionally ignored",
  "legacy session chunk body fail-closed comment",
);
assertSectionIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "let markdown = SessionLogMarkdownFormatter.markdown(for: record)",
  "try await encryptedCloudClient.commitEncryptedSearchIndex",
  "let privateProjectSearchText = Self.clampedPrivateSearchText(record.projectName)",
  "session project text stays local for keyed hashes",
);
assertSectionNotIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "let markdown = SessionLogMarkdownFormatter.markdown(for: record)",
  "try await encryptedCloudClient.commitEncryptedSearchIndex",
  '"projectName"',
  "session-log upload raw project field",
);
assertSectionNotIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "static func facetFields(",
  "func uploadProjectMemorySnapshot",
  '"workingDirectory"',
  "session-log raw working directory facet",
);
assertNotIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  'compactMap { $0.data()["body"] as? String }',
  "legacy Firestore session-log body reassembly",
);
assertNotIncludes(
  "functions/src/callables/remoteMcp.ts",
  '.select("docId", "sessionId", "deviceId", "bodyHash", "title", "snippet", "projectName", "model", "terms")',
  "Remote MCP legacy plaintext stream search",
);
assertIncludes(
  "functions/src/callables/remoteMcp.ts",
  "encryptedSearchRequired: true",
  "Remote MCP encrypted-search-only response",
);
assertSectionNotIncludes(
  "OpenBurnBarMobile/Services/FunctionsRepository.swift",
  "func queryConversations(",
  "static func decodeConversationQueryResponse",
  "projectName",
  "iOS queryConversations project filter payload",
);
assertSectionNotIncludes(
  "android/app/src/main/java/com/openburnbar/data/firebase/FunctionsRepository.kt",
  "suspend fun queryConversations(",
  "suspend fun encryptedSessionBlobDownloadURL",
  "projectName",
  "Android queryConversations project filter payload",
);
assertSectionNotIncludes(
  "OpenBurnBarMobile/Models/ActivityStore.swift",
  "struct CloudConversationSearchRow",
  "private struct CloudConversationSearchReranker",
  "projectName",
  "iOS encrypted cloud search row raw project field",
);
assertSectionNotIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudConversationSearchService.kt",
  "data class CloudConversationSearchRow",
  "class CloudConversationSearchService",
  "projectName",
  "Android encrypted cloud search row raw project field",
);
assertNotIncludes(
  "OpenBurnBarMobile/Views/Streams/StreamsView.swift",
  'TextField("Any project"',
  "iOS cockpit project filter field",
);
assertNotIncludes(
  "android/app/src/main/java/com/openburnbar/ui/streams/ConversationCockpitScreenDetailSections.kt",
  'placeholder = { Text("Any project") }',
  "Android cockpit project filter field",
);
assertIncludes(
  "OpenBurnBarMobile/Views/SessionLogsView.swift",
  "Encrypted transcript matches",
  "iOS Session Logs encrypted cloud search results",
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
