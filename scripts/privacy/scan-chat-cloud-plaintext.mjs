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

function assertNotMatches(relativePath, pattern, note) {
  const text = readRel(relativePath);
  if (pattern.test(text)) {
    fail(`${relativePath}: matches forbidden ${note ?? pattern.toString()}`);
  }
}

function assertSectionIncludes(relativePath, startNeedle, endNeedle, needle, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (!section.includes(needle)) {
    fail(`${relativePath}: ${note ?? "section assertion failed"}`);
  }
}

function assertSectionIncludesAny(relativePath, startNeedle, endNeedle, needles, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (!needles.some((needle) => section.includes(needle))) {
    fail(`${relativePath}: ${note ?? "section assertion failed"}`);
  }
}

function assertSectionNotIncludes(relativePath, startNeedle, endNeedle, needle, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (section.includes(needle)) {
    fail(`${relativePath}: ${note ?? `section contains forbidden ${JSON.stringify(needle)}`}`);
  }
}

function assertSectionNotMatches(relativePath, startNeedle, endNeedle, pattern, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (pattern.test(section)) {
    fail(`${relativePath}: ${note ?? `section matches forbidden ${pattern.toString()}`}`);
  }
}

function assertSectionMatches(relativePath, startNeedle, endNeedle, pattern, note) {
  const section = sectionBetween(relativePath, startNeedle, endNeedle);
  if (!pattern.test(section)) {
    fail(`${relativePath}: ${note ?? `section missing required ${pattern.toString()}`}`);
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

for (const field of [
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
]) {
  assertSectionNotIncludes(
    "firestore.rules",
    "function validCliAgentMissionRequest()",
    "&& request.resource.data.id is string",
    `"${field}"`,
    `validCliAgentMissionRequest allowlist must exclude plaintext field ${field}`,
  );
}

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
}
assertSectionIncludes(
  "firestore.rules",
  "function ownerWritableSessionLogManifest(",
  "function validSessionLogFacetCount(",
  'request.resource.data.inferredTaskTitle == "Encrypted session"',
  "session-log manifest only accepts the generic inferredTaskTitle placeholder",
);
assertNotIncludes(
  "firestore.rules",
  ".all(",
  "unsupported Firestore Rules list predicate in privacy-critical hash validation",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/session_logs/{logId}",
  "match /users/{userId}/project_memory_snapshots/{docID}",
  "allow create, update: if false;",
  "legacy session_logs/{id}/chunks client writes must be server-only",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/cloud_search_chunks/{chunkId}",
  "match /users/{userId}/cloud_search_postings/{postingId}",
  "allow create, update: if false;",
  "cloud_search_chunks client writes must be server-only",
);
assertIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "private static let cloudSearchChunkMaxBytes = 16_000",
  "Mac session-log search chunk size preserves encrypted search recall",
);
assertIncludes(
  "AgentLens/Services/CloudSync/SessionLogSyncService.swift",
  "private static let cloudSearchChunkTokenHashLimit = 1_024",
  "Mac session-log token hash writes preserve encrypted search recall",
);
assertIncludes(
  "functions/src/callables/encryptedSearch.ts",
  'const tokenHashes = requireTokenHashes(raw.tokenHashes, "chunk.tokenHashes");',
  "commitEncryptedSearchIndexBatch must validate token hash arrays in trusted code",
);
assertIncludes(
  "functions/src/callables/encryptedSearch.ts",
  'const semanticHashes = requireOptionalSearchHashes(raw.semanticHashes, "chunk.semanticHashes");',
  "commitEncryptedSearchIndexBatch must validate semantic hash arrays in trusted code",
);
for (const collection of ["cloud_search_documents", "cloud_search_chunks", "cloud_search_postings"]) {
  assertIncludes(
    "AgentLens/Services/CloudSync/ConversationTombstoneGCService.swift",
    collection,
    `tombstone GC must purge ${collection} rows after retention`,
  );
}
for (const script of [
  "functions/scripts/backfill-legacy-session-log-cloud-search-v3.mjs",
  "functions/scripts/upload-local-sqlite-session-logs-v4.mjs",
]) {
  assertIncludes(script, "const CHUNK_MAX_BYTES = 16_000;", `${script} preserves encrypted search chunk capacity`);
  assertIncludes(script, "const CHUNK_TOKEN_HASH_LIMIT = 1_024;", `${script} preserves encrypted search hash capacity`);
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
assertNotIncludes(
  "packages/data-domains/registry.json",
  '"agent_notification_events": "Ephemeral notification queue."',
  "notification events must not be hidden from data domains",
);
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

// ── Semantic hasOnly([ presence per sensitive rules helper ──────────────────
// Every sensitive write helper must positively allowlist its keys, not just
// deny known plaintext fields. (assertRulesRejectFields above only checks the
// hasAny denylist; this asserts the fail-closed allowlist is present too.)
for (const [section, note] of [
  ["function validConversationMirror()", "validConversationMirror lacks keys().hasOnly allowlist"],
  ["function validMobileAssistantChatMirror()", "validMobileAssistantChatMirror lacks keys().hasOnly allowlist"],
  ["function validCliSessionMirror()", "validCliSessionMirror lacks keys().hasOnly allowlist"],
  ["function validCliAgentMissionRequest()", "validCliAgentMissionRequest lacks keys().hasOnly allowlist"],
  ["function relayRequestWrite(", "relayRequestWrite lacks keys().hasOnly allowlist"],
  ["function relayChunkWrite(", "relayChunkWrite lacks keys().hasOnly allowlist"],
  ["function ownerWritableSessionLogManifest(", "session-log manifest lacks keys().hasOnly allowlist"],
  ["function validProjectMemorySnapshotKeys()", "project_memory_snapshots lacks keys().hasOnly allowlist"],
  ["function validMediaSessionEventKeys()", "media_session_events lacks keys().hasOnly allowlist"],
  ["function validMediaAttachmentManifestKeys()", "media_attachment_manifests lacks keys().hasOnly allowlist"],
]) {
  assertRulesSectionHasOnly(section, note);
}

// ── CloudVault sealed payload v2: AAD-bound, v1 read-only compatibility ─────
// New client writes must emit the schema-2 payload envelope with an explicit AAD
// context. Readers may still open old schema-1 payloads locally, but Firestore
// rules must no longer accept v1 sealed-content writes.
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
  "public static let currentSealedPayloadSchemaVersion = 2",
  "Swift CloudVault must write sealedPayload schemaVersion 2",
);
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
  'public static let aadContextPrefix = "OpenBurnBar-CloudVault-aad-v2"',
  "Swift CloudVault must use the six-part aad-v2 context",
);
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
  "\\(field)|\\(schemaVersion)|\\(purpose)",
  "Swift CloudVault AAD must bind field, schemaVersion, and purpose",
);
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
  "public static let sealedPayloadAADContext = \"OpenBurnBar-CloudVaultSealedPayload-v2\"",
  "Swift CloudVault must publish the sealedPayload v2 AAD context",
);
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift",
  "authenticating: sealedPayloadAAD(for:",
  "Swift CloudVault sealedPayload v2 must authenticate envelope metadata as AAD",
);
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
  "const val currentSealedPayloadSchemaVersion: Int = 2",
  "Android CloudVault must write sealedPayload schemaVersion 2",
);
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
  'const val aadContextPrefix: String = "OpenBurnBar-CloudVault-aad-v2"',
  "Android CloudVault must use the six-part aad-v2 context",
);
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
  "|$schemaVersion|$purpose",
  "Android CloudVault AAD must bind field, schemaVersion, and purpose",
);
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
  "private const val SEALED_PAYLOAD_AAD_CONTEXT = \"OpenBurnBar-CloudVaultSealedPayload-v2\"",
  "Android CloudVault must publish the sealedPayload v2 AAD context",
);
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt",
  "cipher.updateAAD(sealedPayloadAAD(",
  "Android CloudVault sealedPayload v2 must authenticate envelope metadata as AAD",
);
assertSectionIncludes(
  "firestore.rules",
  "function validCloudSealedPayload(value)",
  "function matchesCurrentVaultKey",
  "value.schemaVersion == 2",
  "Firestore rules must require CloudVault sealedPayload schemaVersion 2 for new writes",
);
assertSectionIncludes(
  "firestore.rules",
  "function validCloudSealedPayload(value)",
  "function matchesCurrentVaultKey",
  'value.aad == "OpenBurnBar-CloudVaultSealedPayload-v2"',
  "Firestore rules must require the CloudVault sealedPayload v2 AAD context",
);
assertIncludes(
  "functions/src/callables/shared.ts",
  'const CLOUD_VAULT_AAD_CONTEXT_PREFIX = "OpenBurnBar-CloudVault-aad-v2"',
  "Functions validators must use the six-part aad-v2 context",
);
assertIncludes(
  "firestore.rules",
  "OpenBurnBar-CloudVault-aad-v2\\\\|[^|]+\\\\|[^|]+\\\\|[^|]+\\\\|[^|]+\\\\|[2-9][0-9]*\\\\|[^|]+",
  "Firestore rules must validate six-part CloudVault aad-v2 contexts",
);
assertNotIncludes(
  "firestore.rules",
  "sealedSchemaVersion == 1",
  "Firestore rules must not accept v1 sealed-content write gates",
);

// ── project_memory_snapshots: opaque doc id, no project-identity plaintext ───
// The project name lives only inside the sealed snapshot; the doc id is an
// opaque vault-keyed HMAC. The rules must reject the old plaintext duplicates
// and the name-derived slug, and require the sealed body + schemaVersion >= 2.
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/project_memory_snapshots/{docID}",
  "match /users/{userId}/cloud_search_documents",
  '!("projectDisplayName" in request.resource.data)',
  "project_memory_snapshots must reject plaintext projectDisplayName",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/project_memory_snapshots/{docID}",
  "match /users/{userId}/cloud_search_documents",
  '!("projectSlug" in request.resource.data)',
  "project_memory_snapshots must reject name-derived projectSlug",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/project_memory_snapshots/{docID}",
  "match /users/{userId}/cloud_search_documents",
  "request.resource.data.schemaVersion >= 2",
  "project_memory_snapshots must require the hardened schemaVersion >= 2",
);

// ── knowledge_repos: opaque keyed match token + sealed name, no cleartext ────
// A connected repo stores only repoMatchToken + sealedRepoFullName; the rules
// must reject a client-supplied cleartext repoFullName (the cleartext name is
// observed server-side only transiently for webhook routing, never stored).
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/knowledge_repos/{repoId}",
  "match /users/{userId}/unified_audit_log",
  '!("repoFullName" in request.resource.data)',
  "knowledge_repos must reject client-supplied cleartext repoFullName",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/knowledge_repos/{repoId}",
  "match /users/{userId}/unified_audit_log",
  '!("sourceSlug" in request.resource.data)',
  "knowledge_repos must reject client-supplied cleartext sourceSlug",
);

// ── connectKnowledgeRepo (Admin SDK) must NOT persist a cleartext sourceSlug ──
// firestore.rules BANS sourceSlug on client writes, but the connectKnowledgeRepo
// callable runs with the Admin SDK and BYPASSES rules — so a rules-only check is
// structurally blind to what the callable actually stores. Pin the callable
// source directly: the persisted row must carry only the opaque, server-keyed
// `sourceManifestId` (the manifest doc-id key), never the reversible repo-name-
// derived `sourceSlug` or the transitional `sourceSlugToken`. The cleartext slug
// may be read transiently to DERIVE the token and is explicitly
// FieldValue.delete()'d off legacy rows on re-connect.
// (§4 slug remediation — closes the scanner's Admin-SDK blind spot.)
const KNOWLEDGE_SYNC = "functions/src/callables/knowledgeSync.ts";
const CONNECT_REPO_START = "export const connectKnowledgeRepo = onCall(";
const CONNECT_REPO_END = "export const disconnectKnowledgeRepo = onCall(";
// (a) The persisted row must include the canonical opaque manifest id as an
//     actual written field (object-shorthand `sourceManifestId,`), not merely a
//     comment.
assertSectionMatches(
  KNOWLEDGE_SYNC,
  CONNECT_REPO_START,
  CONNECT_REPO_END,
  /\n\s*sourceManifestId,\s*\n/u,
  "connectKnowledgeRepo must persist the opaque server-keyed sourceManifestId field",
);
// (b) The opaque token must be an HMAC of the cleartext slug (no raw store).
assertIncludes(
  KNOWLEDGE_SYNC,
  "function sourceManifestIdFor(",
  "connectKnowledgeRepo must derive the manifest key by HMAC (sourceManifestIdFor)",
);
assertIncludes(
  KNOWLEDGE_SYNC,
  'createHmac("sha256", secret).update(`manifest|${uid}|${sourceSlug}`',
  "sourceManifestIdFor must HMAC the cleartext slug under the manifest domain prefix",
);
// (c) The persist block must NOT write the cleartext slug as an object-shorthand
//     field (`sourceSlug,`) — the only allowed sourceSlug write here is the
//     defensive FieldValue.delete() that strips a stale legacy plaintext field.
assertSectionNotMatches(
  KNOWLEDGE_SYNC,
  CONNECT_REPO_START,
  CONNECT_REPO_END,
  /\n\s*sourceSlug,\s*\n/u,
  "connectKnowledgeRepo must NOT persist the cleartext sourceSlug as an object field (use sourceManifestId)",
);
// (d) If the cleartext slug is written at all, it must be a delete sentinel
//     (the rest of that line must contain FieldValue.delete() — never a value).
//     The lookahead spans the whole line so greedy-whitespace backtracking can't
//     defeat it.
assertSectionNotMatches(
  KNOWLEDGE_SYNC,
  CONNECT_REPO_START,
  CONNECT_REPO_END,
  /\n\s*sourceSlug:(?![^\n]*FieldValue\.delete\(\))/u,
  "connectKnowledgeRepo may only write sourceSlug as FieldValue.delete() (strip legacy), never a value",
);
assertIncludes(
  "functions/src/callables/knowledgeMemory.ts",
  "rootPath is private and must stay sealed on device.",
  "configureKnowledgeSource must reject rootPath",
);
assertNotIncludes(
  "AgentLens/Services/CloudSync/KnowledgeSyncService.swift",
  'payload["rootPath"]',
  "Knowledge sync must not send rootPath to the server",
);
assertSectionNotIncludes(
  "functions/src/callables/knowledgeMemory.ts",
  "configureKnowledgeSource",
  "deleteKnowledgeSource",
  "rootPath,",
  "knowledge manifests must not store rootPath",
);
assertSectionIncludes(
  "firestore.rules",
  "match /users/{userId}/budgetEvents/{eventId}",
  "match /users/{userId}/conversations/{conversationId}",
  '!("detailJSON" in request.resource.data)',
  "budgetEvents must reject detailJSON",
);
assertNotIncludes(
  "AgentLens/Services/CloudBudgetService.swift",
  '"detailJSON": event.detailJSON as Any',
  "macOS cloud budget events must not upload detailJSON",
);
assertNotIncludes(
  "OpenBurnBarMobile/Models/BudgetRulesStore.swift",
  '"detailJSON": event.detailJSON as Any',
  "iOS cloud budget events must not upload detailJSON",
);
assertNotIncludes(
  "android/app/src/main/java/com/openburnbar/data/firebase/FirestoreRepository.kt",
  '"detailJSON" to detailJSON',
  "Android cloud budget events must not upload detailJSON",
);

// ── Hosted chat gateway: server-only writer, NOW sealed end-to-end ───────────
// The gateway collections stay server-written (allow write: if false); the
// sealing happens at the producer (iOS seals events, the agent seals
// messages/attachments) and the sealed-only contract is enforced in the
// callable/HTTP handlers. We still assert the rule denies any direct client
// write, AND that the data export's seal-aware serializer drops plaintext
// text/senderDisplayName/fileName for these collections (gateway-e2e Wave 4).
assertRulesBlockDeniesClientWrite(
  "match /users/{userId}/hermes_gateway_messages/{messageId}",
  "hermes_gateway_messages must deny client writes (server-only writer)",
);
assertRulesBlockDeniesClientWrite(
  "match /users/{userId}/hermes_gateway_events/{eventId}",
  "hermes_gateway_events must deny client writes (server-only writer)",
);
assertRulesBlockDeniesClientWrite(
  "match /users/{userId}/hermes_gateway_attachments/{attachmentId}",
  "hermes_gateway_attachments must deny client writes (server-only writer)",
);
assertRulesBlockDeniesClientWrite(
  "match /users/{userId}/hermes_gateway_approvals/{approvalId}",
  "hermes_gateway_approvals must deny client writes (server-only writer)",
);

// ── Hermes Gateway callable source: the seal gate lives in the handler ───────
// Gateway docs are server-WRITTEN (rules say `allow write: if false`), so
// firestore.rules cannot catch a plaintext persist — the sealed-only contract is
// enforced in the callable. Pin the gate so a regression that drops it (lets a
// relay-capable client smuggle plaintext, or hardcodes the legacy protocol)
// fails red here. (F8 — close the scanner's server-source blind spot.)
const HERMES_GATEWAY_CALLABLE = "functions/src/callables/hermesGateway.ts";
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "requireProductionGatewayRelayEnvelope(",
  "gateway callable must require a production v2/v3 sealed relayEnvelope for relay-capable clients",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "requireProductionGatewayRatchetEnvelope(",
  "gateway callable must validate ratchetEnvelope before storing or forwarding it",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "ambiguous_ciphertext",
  "gateway callable must reject writes that supply both relayEnvelope and ratchetEnvelope",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "gatewayPlaintextWriteAllowed(",
  "gateway callable must gate any plaintext body on the grace-window check",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "ciphertext_required",
  "gateway callable must reject plaintext with ciphertext_required once sealing is mandatory",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "protocolVersion: HERMES_GATEWAY_PROTOCOL_VERSION",
  "gateway /state must advertise the constant protocol version (sealed contract = 2)",
);
assertNotIncludes(
  HERMES_GATEWAY_CALLABLE,
  "protocolVersion: 1",
  "gateway callable must NOT hardcode the legacy plaintext protocol version 1",
);
// Oversight gate is CONTROL-PLANE only: the server must never persist a
// client-supplied free-text approval `summary` (the action detail flows E2E
// sealed over the message channel). Pin that the leak path is gone so a
// regression re-adding it fails red here.
assertNotIncludes(
  HERMES_GATEWAY_CALLABLE,
  "sanitizeHermesGatewayApprovalSummary(body.summary)",
  "oversight gate must NOT persist client-supplied summary text (control-plane only)",
);
assertIncludes(
  HERMES_GATEWAY_CALLABLE,
  "CONTROL-PLANE only",
  "oversight gate must document the control-plane privacy boundary",
);

// ── Pensieve knowledge callables: keyed-dedup + cloaked-vector contract ──────
// The vector rows are server-written/server-read, so firestore.rules cannot see
// a re-introduced cleartext oracle. Pin the callable contract: dedup is a
// vault-keyed HMAC (versioned), the embedding is cloaked, and recall floors out
// legacy v0 cleartext-hash rows. (F8 — server-source blind spot.)
const KNOWLEDGE_MEMORY = "functions/src/callables/knowledgeMemory.ts";
assertIncludes(
  KNOWLEDGE_MEMORY,
  "requireCloakedVector",
  "commitKnowledgeBatch must require a cloaked (not raw bge) embedding",
);
assertIncludes(
  KNOWLEDGE_MEMORY,
  "requireHexDigest(raw.dedupHash",
  "commitKnowledgeBatch must require a vault-keyed dedupHash (no cleartext contentHash oracle)",
);
assertIncludes(
  KNOWLEDGE_MEMORY,
  "dedupHashVersion",
  "knowledge vectors must carry a dedupHashVersion so legacy cleartext-hash rows are fenced out",
);
assertIncludes(
  "functions/src/callables/knowledgeSearch.ts",
  '.where("dedupHashVersion", "==", 1)',
  "knowledgeSearch must floor dedupHashVersion == 1 so legacy cleartext-hash rows are never served",
);

// ── Sealed-content export coverage (dataExport seal-aware serializer) ────────
// The export of the sealed gateway/media/subscription content must round-trip
// ONLY structurally valid opaque sealed envelopes — never plaintext text /
// senderDisplayName / fileName / agentURI / topicID. These assertions pin the
// shape-aware export path so a regression that trusts a key name instead of the
// sealed envelope shape fails red.
const DATA_EXPORT = "functions/src/callables/dataExport.ts";
// 1. CloudVault and Hermes envelopes are recognized by sealed shape, not key name.
assertSectionIncludes(
  DATA_EXPORT,
  "export function isSealedEnvelope(",
  "function isExportablePrimitive(",
  'v.algorithm === "AES-256-GCM"',
  "dataExport must detect CloudVault sealed text/blob envelopes structurally",
);
assertSectionIncludes(
  DATA_EXPORT,
  "export function isSealedEnvelope(",
  "function isExportablePrimitive(",
  'v.relayEncryption === "p256-hkdf-sha256-aesgcm"',
  "dataExport must detect the gateway relayEnvelope as a sealed envelope",
);
assertSectionIncludes(
  DATA_EXPORT,
  "export function isSealedEnvelope(",
  "function isExportablePrimitive(",
  'v.relayEncryption === "hpke-auth-p256-hkdfsha256-aes256gcm"',
  "dataExport must detect the HPKE v3 gateway relayEnvelope as a sealed envelope",
);
assertSectionIncludes(
  DATA_EXPORT,
  "export function isSealedEnvelope(",
  "function isExportablePrimitive(",
  'header.algorithm === "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM"',
  "dataExport must detect the gateway ratchetEnvelope as a sealed envelope",
);
// 2. The sealed gateway content collections ride the default-deny seal-aware path
//    even though their parent connected_devices domain is server_readable.
for (const collection of [
  "hermes_gateway_events",
  "hermes_gateway_messages",
  "hermes_gateway_attachments",
]) {
  assertSectionIncludes(
    DATA_EXPORT,
    "const SEAL_AWARE_CONTENT_COLLECTIONS",
    "MAX_INLINE_DOCS_PER_COLLECTION",
    `"${collection}"`,
    `dataExport must force seal-aware serialization for ${collection}`,
  );
}
assertNotIncludes(
  "OpenBurnBarMobile/Services/FunctionsRepository.swift",
  'payload["text"] = text',
  "iOS gateway must not construct plaintext event payloads",
);
assertNotIncludes(
  "OpenBurnBarMobile/Services/FunctionsRepository.swift",
  'payload["senderDisplayName"] = senderDisplayName',
  "iOS gateway must not construct plaintext sender payloads",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  "return false;",
  "gateway plaintext write gate must be permanently closed",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  "HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS",
  "gateway validation must have an explicit production relay-envelope version set",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  "HERMES_GATEWAY_PREFERRED_RELAY_ENVELOPE_VERSION = 3",
  "gateway negotiation must prefer the HPKE-auth v3 relay envelope",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  'HERMES_GATEWAY_RELAY_ENCRYPTION_V3 = "hpke-auth-p256-hkdfsha256-aes256gcm"',
  "gateway validation must know the HPKE-auth v3 encryption marker",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  "negotiateGatewayRelayEnvelopeCapabilities",
  "gateway clients must negotiate v2/v3 relay-envelope capabilities",
);
assertIncludes(
  "functions/src/hermesGateway.ts",
  "preferredRelayEnvelopeVersion: client.preferredRelayEnvelopeVersion",
  "gateway /state public client view must advertise the negotiated preferred relay envelope",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "GATEWAY_HPKE_V3_DISABLED_ENV",
  "Hermes BurnBar adapter must expose an explicit break-glass switch for v3 only",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "versions.append(GATEWAY_RELAY_KEY_VERSION_V3)",
  "Hermes BurnBar adapter must advertise production v2/v3 relay-envelope support by default",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "return versions[-1]",
  "Hermes BurnBar adapter must prefer the HPKE-auth v3 relay envelope by default",
);
assertNotIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "BURNBAR_EXPERIMENTAL_GATEWAY_HPKE_V3",
  "Hermes BurnBar adapter must not keep v3 behind the old experimental flag",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "RELAY_PRIVATE_KEY_KEYCHAIN_SERVICE",
  "Hermes BurnBar adapter must persist the agent relay private key in Keychain",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "_load_relay_private_key_base64_from_keychain",
  "Hermes BurnBar adapter must load the agent relay private key from Keychain",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "_store_relay_private_key_base64_to_keychain",
  "Hermes BurnBar adapter must store the agent relay private key in Keychain",
);
assertIncludes(
  "OpenBurnBarMobile/Services/FunctionsRepository.swift",
  "sealGatewayEventRatchetPayload(",
  "iOS gateway must prefer ratchetEnvelope for capable phone events",
);
assertIncludes(
  "OpenBurnBarMobile/Services/FunctionsRepository.swift",
  "decodedRatchetText(",
  "iOS gateway must open ratchetEnvelope agent replies",
);
assertIncludes(
  "OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift",
  "HermesGatewayRatchetSessionStore",
  "iOS gateway must persist chat ratchet session state",
);
assertIncludes(
  "OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift",
  "loadCurrentChatSessionID(",
  "iOS gateway must remember the current chat ratchet session",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "def _seal_ratchet_message(",
  "Hermes BurnBar adapter must prefer ratchetEnvelope for capable agent replies",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "def _open_ratchet_event(",
  "Hermes BurnBar adapter must open ratchetEnvelope phone events",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "RATCHET_SESSION_KEYCHAIN_SERVICE",
  "Hermes BurnBar adapter must persist chat ratchet sessions in Keychain",
);
assertIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "BURNBAR_RATCHET_CHAT_SESSION_ID",
  "Hermes BurnBar adapter must persist the non-secret current chat ratchet session id",
);
assertIncludes(
  "OpenBurnBarMobileTests/OpenBurnBarMobileTests.swift",
  "testHermesGatewayRatchetChatLaneRoundTripsPhoneEventAndAgentReply",
  "mobile tests must prove the live chat ratchet event/reply round trip",
);
assertNotIncludes(
  "docs/HERMES_GATEWAY_RATCHET_PROTOCOL.md",
  "default gateway transport still uses `relayEnvelope`",
  "ratchet protocol docs must not claim live text transport is relay-only",
);
assertNotIncludes(
  "docs/runbooks/hermes-gateway-3features.md",
  "Transport still emits/opens `relayEnvelope`",
  "gateway runbook must not claim live text transport is relay-only",
);
assertNotIncludes(
  "docs/runbooks/hermes-gateway-3features-HANDOFF.md",
  "Transport still emits/opens `relayEnvelope`",
  "gateway handoff must not claim live text transport is relay-only",
);
assertNotIncludes(
  "tools/hermes-platform-burnbar/adapter.py",
  "persist=save_env_value",
  "Hermes BurnBar adapter must not persist relay private keys through ~/.hermes/.env",
);
assertNotMatches(
  "tools/hermes-platform-burnbar/adapter.py",
  /save_env_value\([^)\n]*RELAY_PRIVATE_KEY_ENV/,
  "Hermes BurnBar adapter must not write BURNBAR_RELAY_PRIVATE_KEY with save_env_value",
);
for (const rotationFile of [
  "OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift",
  "tools/hermes-platform-burnbar/adapter.py",
  "functions/src/callables/hermesGateway.ts",
]) {
  assertNotIncludes(
    rotationFile,
    "Signed key rotation is a deferred follow-up",
    `${rotationFile} must state the implemented re-pair-only rotation contract`,
  );
}

// ── Iroh direct relay terminal errors: public fixed codes, no plaintext ─────
// The direct iroh relay runs outside Firestore, so rules/backfill cannot save
// us if a Mac starts serializing a peer-visible exception string into
// response.error. Pin both directions: senders emit only errorCode, receivers
// ignore the legacy plaintext field and map known codes to fixed public text.
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift",
  "public enum HermesRealtimeRelayErrorCode",
  "Swift iroh relay frame model must carry fixed public error codes",
);
assertIncludes(
  "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRealtimeRelayTypes.swift",
  "public var errorCode: String?",
  "Swift iroh relay payload must expose errorCode",
);
assertIncludes(
  "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/HermesRealtimeRelayFrame.kt",
  "val errorCode: String? = null",
  "Android iroh relay payload must expose errorCode",
);
for (const sender of [
  "AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift",
  "AgentLens/Services/HermesRealtimeRelayHostClient.swift",
]) {
  assertIncludes(
    sender,
    "HermesRealtimeRelayErrorCode.requestFailed.rawValue",
    `${sender} must emit a fixed request_failed terminal error code`,
  );
  assertNotIncludes(
    sender,
    "HermesRealtimeRelayPayload(error:",
    `${sender} must not serialize plaintext terminal errors`,
  );
}
for (const receiver of [
  "OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift",
  "OpenBurnBarMobile/Services/HermesService.swift",
  "OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/HermesIrohEcho.swift",
]) {
  assertIncludes(
    receiver,
    "HermesRealtimeRelayErrorCode.publicMessage(for: frame.payload?.errorCode)",
    `${receiver} must map response.error from fixed public errorCode`,
  );
  assertNotMatches(
    receiver,
    /frame\.payload\?\.error(?!Code)\b/u,
    `${receiver} must ignore legacy plaintext terminal errors`,
  );
}
for (const relayLogSurface of [
  "AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift",
  "AgentLens/Services/IrohRelay/HermesIrohRelayHostClient.swift",
  "AgentLens/Services/IrohRelay/IrohRelayKeyStore.swift",
  "AgentLens/Services/IrohRelay/IrohPairingKeyStore.swift",
  "OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift",
  "OpenBurnBarMobile/Services/IrohRelay/IrohTransportAuditLogger.swift",
]) {
  assertNotIncludes(
    relayLogSurface,
    "localizedDescription",
    `${relayLogSurface} must log fixed error classes/codes instead of plaintext exception descriptions`,
  );
}
assertIncludes(
  "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesIrohRelayTransport.kt",
  "publicRelayErrorMessage(frame.payload?.errorCode)",
  "Android iroh relay client must map response.error from fixed public errorCode",
);
assertNotMatches(
  "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesIrohRelayTransport.kt",
  /frame\.payload\?\.error(?!Code)\b/u,
  "Android iroh relay client must ignore legacy plaintext terminal errors",
);
assertSectionIncludes(
  "OpenBurnBarMobile/Services/HermesService.swift",
  "private func chunkRecord(",
  "private func receiveFrame",
  "guard let ciphertext = payload.ciphertext",
  "hosted realtime chunks, including terminal errors, must require ciphertext before decode",
);
// Gateway relayed content is scrubbed UNCONDITIONALLY (sealed AND legacy docs),
// via the `gatewayRelayed` gate — NOT `requires:"relayEnvelope"`, which was a
// structural no-op for legacy schema<2 server docs and is the audit BLOCKER
// "legacy gateway plaintext never auto-scrubbed." These assertions pin the fix
// and forbid a regression back to the no-op gate.
assertSectionIncludes(
  "functions/src/callables/privacyBackfill.ts",
  'collection: "hermes_gateway_messages"',
  'collection: "hermes_gateway_attachments"',
  '{ field: "threadId", gatewayRelayed: true }',
  "privacy backfill must scrub gateway message threadId unconditionally (sealed + legacy)",
);
assertSectionIncludes(
  "functions/src/callables/privacyBackfill.ts",
  'collection: "hermes_gateway_messages"',
  'collection: "hermes_gateway_attachments"',
  '{ field: "replyToEventId", gatewayRelayed: true }',
  "privacy backfill must scrub gateway message replyToEventId unconditionally (sealed + legacy)",
);
assertSectionNotIncludes(
  "functions/src/callables/privacyBackfill.ts",
  'collection: "hermes_gateway_messages"',
  'collection: "hermes_gateway_attachments"',
  'requires: "relayEnvelope"',
  "gateway plaintext must NOT be gated on relayEnvelope (no-op for legacy docs — the BLOCKER)",
);
// 3. Sealed envelope keys for media filename + subscription graph must NOT be
//    key-only opaque columns. They pass only when the value is structurally
//    recognized by isSealedEnvelope(), so a bad cleartext value under a trusted
//    key name is still dropped.
for (const sealedKey of ["sealedFilename", "sealedAgentURI", "sealedTopicID", "relayEnvelope", "ratchetEnvelope"]) {
  assertSectionNotIncludes(
    DATA_EXPORT,
    "const OPAQUE_EXPORT_COLUMNS",
    "export function isSealedEnvelope(",
    `"${sealedKey}"`,
    `dataExport OPAQUE_EXPORT_COLUMNS must not key-allowlist sealed envelope key ${sealedKey}`,
  );
}
for (const plaintextKey of ["text", "senderDisplayName", "fileName", "filename"]) {
  assertSectionNotIncludes(
    DATA_EXPORT,
    "const OPAQUE_EXPORT_COLUMNS",
    "export function isSealedEnvelope(",
    `"${plaintextKey}"`,
    `dataExport OPAQUE_EXPORT_COLUMNS must NOT allowlist plaintext ${plaintextKey} (it must be dropped)`,
  );
}

// ── media_attachment_manifests: sealed filename, never plaintext alongside ───
// The hardened shape is sealedFilename (validCloudSealedText); when present, no
// plaintext filename may ride along, and payload bytes are always rejected.
assertSectionIncludes(
  "firestore.rules",
  "function validMediaAttachmentManifestKeys()",
  "match /users/{userId}/pi_agent_connections",
  "validCloudSealedText(request.resource.data.sealedFilename)",
  "media_attachment_manifests must validate sealedFilename as a sealed envelope",
);
assertSectionIncludes(
  "firestore.rules",
  "function validMediaAttachmentManifestKeys()",
  "match /users/{userId}/pi_agent_connections",
  '!("body" in request.resource.data)',
  "media_attachment_manifests must reject raw payload body",
);

// ── Hermes Square device-only surfaces: seal private text, hasOnly allowlist ─
// approval_policies, cli_sessions/*/snapshots, rollback_requests,
// agent_identities, and subscription_topics each carry device-private free-text
// (project/file/glob labels, rollback scope paths + error diagnostics, persona
// identity strings, subscription display text). They are pure store-and-forward
// between the user's own devices — the server reads none of them. Each write
// helper must (a) positively allowlist its keys with keys().hasOnly([ (fail
// closed), (b) carry the sealed fields validated by validCloudSealedText, and
// (c) reject the bare plaintext key — either outright (no legacy writer) or via
// rejectsPlaintextWhenSealed once its sealed copy is present (migration-safe).
// (privacy-leak-remediation W3)

// Each entry declares sealed fields, required sealed fields, and plaintext keys
// that must not be accepted on client writes. rejectMode:
//   - "outright": explicit `!("x" in …)` guard
//   - "absentFromAllowlist": plaintext key absent from the hasOnly allowlist
const W3_SEALED_SURFACES = [
  {
    label: "approval_policies",
    start: "match /users/{userId}/approval_policies/{policyId}",
    end: "match /users/{userId}/rollback_requests",
    sealed: ["sealedDisplayLabel", "sealedFileGlob", "sealedTargetProject"],
    requiredSealed: ["sealedDisplayLabel"],
    plaintext: ["id", "displayLabel", "fileGlob", "targetProject"],
    rejectMode: "absentFromAllowlist",
  },
  {
    label: "rollback_requests",
    start: "match /users/{userId}/rollback_requests/{requestId}",
    end: "match /users/{userId}/cli_sessions/{sessionId}/snapshots",
    sealed: ["sealedScope", "sealedErrorMessage"],
    requiredSealed: ["sealedScope"],
    plaintext: ["scopeJSON", "errorMessage"],
    rejectMode: "absentFromAllowlist",
  },
  {
    label: "cli_sessions/*/snapshots",
    start: "match /users/{userId}/cli_sessions/{sessionId}/snapshots/{snapshotId}",
    end: "match /users/{userId}/agent_identities",
    sealed: ["sealedActionLabel", "sealedTouchedFiles", "sealedMacSnapshotPath"],
    requiredSealed: ["sealedActionLabel"],
    plaintext: ["actionLabel", "touchedFiles", "macSnapshotPath"],
    rejectMode: "absentFromAllowlist",
  },
  {
    label: "agent_identities",
    start: "match /users/{userId}/agent_identities/{identityId}",
    end: "match /users/{userId}/subscription_topics",
    sealed: ["sealedDisplayName", "sealedTagline", "sealedPersonas"],
    requiredSealed: [],
    plaintext: ["displayName", "tagline", "personas"],
    rejectMode: "outright",
  },
  {
    label: "subscription_topics",
    start: "match /users/{userId}/subscription_topics/{topicId}",
    end: "match /users/{userId}/session_logs",
    sealed: ["sealedAgentURI", "sealedTopicID", "sealedDisplayName", "sealedDescription"],
    requiredSealed: ["sealedAgentURI", "sealedTopicID", "sealedDisplayName", "sealedDescription"],
    plaintext: ["agentURI", "topicID", "displayName", "description"],
    rejectMode: "absentFromAllowlist",
  },
];

for (const surface of W3_SEALED_SURFACES) {
  // (a) SEMANTIC allowlist: the block must positively constrain its key set.
  assertSectionIncludes(
    "firestore.rules",
    surface.start,
    surface.end,
    "request.resource.data.keys().hasOnly([",
    `${surface.label} must allowlist its keys with keys().hasOnly([ (fail closed)`,
  );
  // (b) Each private field must be sealed and validated as a sealed envelope.
	  for (const sealedField of surface.sealed) {
	    assertSectionIncludesAny(
	      "firestore.rules",
	      surface.start,
	      surface.end,
	      [
	        `validCloudSealedText(request.resource.data.${sealedField})`,
	        `"${sealedField}", request.resource.data.${sealedField}`,
	      ],
	      `${surface.label} must validate ${sealedField} as a sealed envelope`,
	    );
	  }
  // Required sealed fields must not be optional migration gates. This prevents
  // plaintext-only create windows from passing the scan.
  for (const sealedField of surface.requiredSealed ?? []) {
    assertSectionNotIncludes(
      "firestore.rules",
      surface.start,
      surface.end,
      `!("${sealedField}" in request.resource.data) || validCloudSealedText(request.resource.data.${sealedField})`,
      `${surface.label} must require ${sealedField}, not make it optional`,
    );
  }
  // (c) Reject the bare plaintext key name.
  for (let i = 0; i < surface.plaintext.length; i += 1) {
    const plaintextKey = surface.plaintext[i];
    if (surface.rejectMode === "outright") {
      // No legacy migration window — cleartext is rejected unconditionally.
      assertSectionIncludes(
        "firestore.rules",
        surface.start,
        surface.end,
        `!("${plaintextKey}" in request.resource.data)`,
        `${surface.label} must reject plaintext ${plaintextKey} outright`,
      );
    } else if (surface.rejectMode === "absentFromAllowlist") {
      // Sealed-only contract: the plaintext key is dropped from the allowlist, so
      // it never appears as a quoted allowlist member.
      assertSectionNotIncludes(
        "firestore.rules",
        surface.start,
        surface.end,
        `"${plaintextKey}"`,
        `${surface.label} allowlist must not contain plaintext ${plaintextKey} (sealed-only from day one)`,
      );
    }
  }
}

// ── Registry honesty: usage project text + gateway label + pensieve repo ─────
// Mirrors the registry.test.mjs honesty assertions so the privacy scan also
// fails red if the public-facing labels regress to overclaiming.
function assertRegistryPrivacyHonesty() {
  const registry = JSON.parse(readRel("packages/data-domains/registry.json"));
  const domain = (id) => registry.domains.find((entry) => entry.id === id);

  const usage = domain("usage_spend");
  if (!usage) {
    fail("packages/data-domains/registry.json: missing usage_spend domain");
  } else {
    if (usage.serverSees.map((v) => v.toLowerCase()).includes("project")) {
      fail("packages/data-domains/registry.json: usage_spend serverSees still claims plaintext project");
    }
    if (!usage.serverSees.some((v) => /opaque/i.test(v) && /hash/i.test(v))) {
      fail("packages/data-domains/registry.json: usage_spend must declare the opaque project hash");
    }
    if (!usage.deviceOnly.some((v) => v.toLowerCase().includes("project name"))) {
      fail("packages/data-domains/registry.json: usage_spend deviceOnly must list project names");
    }
  }

  const pensieve = domain("pensieve");
  if (!pensieve) {
    fail("packages/data-domains/registry.json: missing pensieve domain");
  } else {
    if (pensieve.serverSees.some((v) => /repo\s*name|repofullname|repo full name/i.test(v))) {
      fail("packages/data-domains/registry.json: pensieve serverSees must not claim it reads the cleartext repo name");
    }
    if (!pensieve.serverSees.some((v) => /opaque/i.test(v) && /match token/i.test(v))) {
      fail("packages/data-domains/registry.json: pensieve must declare the opaque repo match token");
    }
    if (!/NOTE:/.test(pensieve.summary) || !/webhook/i.test(pensieve.summary)) {
      fail("packages/data-domains/registry.json: pensieve summary must carry the webhook-routing caveat");
    }
  }

  const devices = domain("connected_devices");
  if (!devices) {
    fail("packages/data-domains/registry.json: missing connected_devices domain");
  } else {
    // Gateway-e2e Wave 4: the hosted chat gateway is now sealed end-to-end
    // (HermesRelayCrypto), so the server must NOT claim it reads gateway message
    // text / sender names / attachment file names anymore.
    for (const leak of [/message text/i, /sender name/i, /file name/i]) {
      if (devices.serverSees.some((v) => /gateway/i.test(v) && leak.test(v))) {
        fail(`packages/data-domains/registry.json: connected_devices serverSees must not claim the server reads gateway ${leak.source} (the gateway is sealed)`);
      }
    }
    if (!devices.serverSees.some((v) => /opaque/i.test(v) && /key material/i.test(v))) {
      fail("packages/data-domains/registry.json: connected_devices serverSees must declare the opaque relay public-key material");
    }
    if (!devices.deviceOnly.some((v) => /gateway/i.test(v) && /sealed/i.test(v))) {
      fail("packages/data-domains/registry.json: connected_devices deviceOnly must state the gateway frame contents are sealed");
    }
    if (/server can read/i.test(devices.summary)) {
      fail("packages/data-domains/registry.json: connected_devices summary must not say the server can read the gateway");
    }
  }

  const media = domain("media");
  if (!media) {
    fail("packages/data-domains/registry.json: missing media domain");
  } else {
    // Media-filename seal (gateway-e2e Wave 4): the human-readable attachment
    // file name moves to deviceOnly; serverSees keeps only opaque manifest facets.
    if (media.serverSees.some((v) => /file ?name/i.test(v))) {
      fail("packages/data-domains/registry.json: media serverSees must not claim it reads attachment file names (sealedFilename)");
    }
    if (!media.deviceOnly.some((v) => /file ?name/i.test(v) && /seal/i.test(v))) {
      fail("packages/data-domains/registry.json: media deviceOnly must list attachment file names as sealed/device-only");
    }
  }

  // W3 sealed private collections: folded into the sealed conversations_chat
  // domain rather than buried in excludedCollections. They carry device-private
  // rollback scope/diagnostics, approval labels/globs/projects, agent persona
  // text, and subscription graph edges.
  const chat = domain("conversations_chat");
  if (!chat) {
    fail("packages/data-domains/registry.json: missing conversations_chat domain");
  } else {
    for (const name of ["rollback_requests", "approval_policies", "agent_identities", "subscription_topics"]) {
      if (!chat.firestorePaths.includes(name)) {
        fail(`packages/data-domains/registry.json: conversations_chat must own the ${name} path`);
      }
    }
    if (!chat.deviceOnly.some((v) => /rollback scope/i.test(v))) {
      fail("packages/data-domains/registry.json: conversations_chat deviceOnly must list rollback scope paths");
    }
    if (!chat.deviceOnly.some((v) => /rollback error/i.test(v))) {
      fail("packages/data-domains/registry.json: conversations_chat deviceOnly must list rollback error diagnostics");
    }
    if (!chat.deviceOnly.some((v) => /approval policy/i.test(v))) {
      fail("packages/data-domains/registry.json: conversations_chat deviceOnly must list approval policy private text");
    }
    if (!chat.deviceOnly.some((v) => /agent persona/i.test(v))) {
      fail("packages/data-domains/registry.json: conversations_chat deviceOnly must list agent persona text");
    }
    if (!chat.deviceOnly.some((v) => /subscription graph/i.test(v))) {
      fail("packages/data-domains/registry.json: conversations_chat deviceOnly must list subscription graph edges");
    }
  }
  for (const name of ["rollback_requests", "approval_policies", "agent_identities", "subscription_topics"]) {
    if (Object.prototype.hasOwnProperty.call(registry.excludedCollections ?? {}, name)) {
      fail(`packages/data-domains/registry.json: ${name} must be removed from excludedCollections once folded into conversations_chat`);
    }
  }
}

assertRegistryPrivacyHonesty();

if (failures.length) {
  console.error("Cloud plaintext hardening scan failed:");
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log("Cloud plaintext hardening scan passed.");
