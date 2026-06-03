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
  "requireGatewayRelayEnvelope(",
  "gateway callable must require a sealed relayEnvelope for relay-capable clients",
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
// ONLY the opaque sealed envelopes — never plaintext text / senderDisplayName /
// fileName / agentURI / topicID. These assertions pin the dataExport allowlist
// so a regression that re-adds a plaintext key (or stops sealing) fails red.
const DATA_EXPORT = "functions/src/callables/dataExport.ts";
// 1. The Hermes gateway relay envelope is recognized as a sealed (opaque) envelope.
assertSectionIncludes(
  DATA_EXPORT,
  "export function isSealedEnvelope(",
  "function isExportablePrimitive(",
  'v.relayEncryption === "p256-hkdf-sha256-aesgcm"',
  "dataExport must detect the gateway relayEnvelope as a sealed envelope",
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
assertSectionIncludes(
  "functions/src/callables/privacyBackfill.ts",
  'collection: "hermes_gateway_messages"',
  'collection: "hermes_gateway_attachments"',
  '{ field: "threadId", requires: "relayEnvelope" }',
  "privacy backfill must scrub sealed gateway message threadId",
);
assertSectionIncludes(
  "functions/src/callables/privacyBackfill.ts",
  'collection: "hermes_gateway_messages"',
  'collection: "hermes_gateway_attachments"',
  '{ field: "replyToEventId", requires: "relayEnvelope" }',
  "privacy backfill must scrub sealed gateway message replyToEventId",
);
// 3. The sealed envelope keys for media filename + subscription graph are
//    recognized opaque columns (so they pass) and the bare plaintext keys are not.
for (const sealedKey of ["sealedFilename", "sealedAgentURI", "sealedTopicID", "relayEnvelope"]) {
  assertSectionIncludes(
    DATA_EXPORT,
    "const OPAQUE_EXPORT_COLUMNS",
    "export function isSealedEnvelope(",
    `"${sealedKey}"`,
    `dataExport OPAQUE_EXPORT_COLUMNS must list the sealed key ${sealedKey}`,
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
    assertSectionIncludes(
      "firestore.rules",
      surface.start,
      surface.end,
      `validCloudSealedText(request.resource.data.${sealedField})`,
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
