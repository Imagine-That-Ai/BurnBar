import path from 'node:path';
import { exactKeys, parseJson, validateArtifact, validateCollectedAt, validateInstalledSessionEnvelope } from './installed-ui-proof.mjs';
import { readRegularSnapshot } from './product-proof-closure.mjs';

export const P14_REQUIREMENT_ID = 'P-14';
export const P14_PROOF_ROLE = 'feature.chat-installed';
export const P14_PROOF_FILENAME = 'chat-installed.json';
export const P14_SESSION_FILENAME = 'p14-installed-chat-session.json';
export const P14_SOURCE_CONTRACTS = Object.freeze([
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarChatThreadService.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonServer+RPCChat.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLISocketClient.swift',
  'OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift',
  'apps/linux-desktop/src-tauri/src/desktop/gateway.rs',
  'apps/linux-desktop/src/state/chatStore.ts',
  'apps/linux-desktop/src/surfaces/chat/chatExport.ts',
  'apps/linux-desktop/src/surfaces/chat/chatWindow.ts'
]);
const MARKERS = {
  [P14_SOURCE_CONTRACTS[0]]: ['BurnBarChatThreadService', 'appendMessage', 'hasMoreBefore'],
  [P14_SOURCE_CONTRACTS[1]]: ['chatThreadList', 'chatMessageAppend'],
  [P14_SOURCE_CONTRACTS[2]]: ['chatThreadList', 'chatThreadGet'],
  [P14_SOURCE_CONTRACTS[3]]: ['runChatQueryCommand', 'chat threads'],
  [P14_SOURCE_CONTRACTS[4]]: ['chat_attachment_upload', 'gateway_chat_stream'],
  [P14_SOURCE_CONTRACTS[5]]: ['loadOlderMessages', 'respondToToolApproval'],
  [P14_SOURCE_CONTRACTS[6]]: ['CHAT_HISTORY_MAX_MESSAGES', 'attachmentId'],
  [P14_SOURCE_CONTRACTS[7]]: ['openChatPopoutWindow', 'closeChatPopoutWindow']
};
const SHA = /^[a-f0-9]{64}$/u;
const REQUIRED_DAEMON = ['append-first', 'append-duplicate', 'pagination', 'search', 'post-restart'];
const REQUIRED_UI = ['model-thinking', 'attachment', 'citation', 'approvals', 'reconnect-visibility', 'export', 'popout', 'attachment-restart-limit'];

function timestamp(value, label) { const n = Date.parse(value); if (!Number.isFinite(n)) throw new Error(`${label} timestamp is invalid`); return n; }
function truth(value, fields, label) { for (const field of fields) if (value[field] !== true) throw new Error(`${label}.${field} is not proven`); }
function sourceEvidence(root, rows) {
  if (!Array.isArray(rows) || rows.length !== P14_SOURCE_CONTRACTS.length) throw new Error('P-14 source evidence is incomplete');
  const seen = new Set();
  for (const row of rows) {
    exactKeys(row, ['path', 'sha256'], 'P-14 source row');
    if (!P14_SOURCE_CONTRACTS.includes(row.path) || seen.has(row.path) || !SHA.test(row.sha256)) throw new Error('P-14 source row is invalid');
    seen.add(row.path);
    const snapshot = readRegularSnapshot(root, row.path, `P-14 source ${row.path}`);
    if (snapshot.sha256 !== row.sha256) throw new Error(`P-14 source changed: ${row.path}`);
    for (const marker of MARKERS[row.path]) if (!snapshot.bytes.toString('utf8').includes(marker)) throw new Error(`${row.path} lacks ${marker}`);
  }
}
function eventMap(document, required, label, start, end) {
  exactKeys(document, ['events', 'producer'], label);
  if (!Array.isArray(document.events) || !document.producer.startsWith('openburnbar-p14-installed-')) throw new Error(`${label} producer is invalid`);
  const map = new Map();
  for (const event of document.events) {
    exactKeys(event, ['at', 'data', 'kind'], `${label} event`);
    const at = timestamp(event.at, `${label} ${event.kind}`);
    if (at < start || at > end || map.has(event.kind)) throw new Error(`${label} event is replayed or out of bounds`);
    map.set(event.kind, event.data);
  }
  if (required.some((kind) => !map.has(kind)) || map.size !== required.length) throw new Error(`${label} target set is incomplete`);
  return map;
}
function validateDaemon(map, threadID) {
  const first = map.get('append-first'); const duplicate = map.get('append-duplicate');
  if (first.threadID !== threadID || first.inserted !== true || !first.messageID
      || duplicate.inserted !== false || duplicate.messageID !== first.messageID) {
    throw new Error('P-14 idempotent send ordering failed');
  }
  truth(map.get('pagination'), ['cursorStable', 'hasMoreBefore', 'messagesUnique', 'ordered'], 'P-14 pagination');
  truth(map.get('search'), ['matchedOnlyTarget', 'queryApplied'], 'P-14 search');
  const restart = map.get('post-restart');
  truth(restart, ['encryptedDatabase', 'messageOrdering', 'messagesDurable', 'metadataDurable'], 'P-14 restart');
  if (restart.threadID !== threadID || restart.messageCount < 2) throw new Error('P-14 restart readback is incomplete');
}
function validateUI(map, threadID) {
  const model = map.get('model-thinking');
  exactKeys(model, ['fixtureMode', 'selectedModel', 'selectedThinking', 'upstreamModel', 'upstreamThinking'], 'P-14 model/thinking');
  if (!model.selectedModel || model.upstreamModel !== model.selectedModel
      || model.selectedThinking !== model.upstreamThinking || model.fixtureMode !== false) throw new Error('P-14 exact model/thinking propagation failed');
  const attachment = map.get('attachment');
  exactKeys(attachment, ['chooserWindowID', 'exportMetadata', 'input', 'postRestartMetadata', 'upstreamAttachment'], 'P-14 attachment');
  exactKeys(attachment.input, ['byteSize', 'fileName', 'mimeType', 'sha256'], 'P-14 attachment input');
  exactKeys(attachment.exportMetadata, ['attachmentId', 'byteSize', 'fileName', 'mimeType', 'sha256'], 'P-14 exported attachment');
  exactKeys(attachment.postRestartMetadata, ['attachmentId', 'byteSize', 'fileName', 'mimeType', 'sha256'], 'P-14 restarted attachment');
  exactKeys(attachment.upstreamAttachment, ['byteSize', 'fileName', 'sha256'], 'P-14 upstream attachment');
  if (!attachment.chooserWindowID || !SHA.test(attachment.input.sha256)
      || attachment.input.byteSize < 1 || attachment.input.byteSize > 10 * 1024 * 1024
      || attachment.input.byteSize !== attachment.exportMetadata.byteSize
      || attachment.input.fileName !== attachment.exportMetadata.fileName
      || attachment.input.mimeType !== attachment.exportMetadata.mimeType
      || attachment.input.sha256 !== attachment.exportMetadata.sha256
      || Object.keys(attachment.exportMetadata).some((key) => attachment.exportMetadata[key] !== attachment.postRestartMetadata[key])
      || attachment.upstreamAttachment.byteSize !== attachment.input.byteSize
      || attachment.upstreamAttachment.fileName !== attachment.input.fileName
      || attachment.upstreamAttachment.sha256 !== attachment.input.sha256) {
    throw new Error('P-14 attachment identity, bounds, export, or restart metadata failed');
  }
  const citation = map.get('citation');
  exactKeys(citation, ['activatedCitationID', 'citedMessageID', 'citedThreadID', 'loadedPageMessageIDs', 'selectedThreadIDAfter', 'status'], 'P-14 citation');
  if (!citation.activatedCitationID || citation.citedThreadID !== threadID || citation.selectedThreadIDAfter !== threadID
      || !citation.citedMessageID || !citation.loadedPageMessageIDs.includes(citation.citedMessageID)
      || citation.status !== 'Cited source message opened.') throw new Error('P-14 citation target/thread validation failed');
  const approvals = map.get('approvals');
  exactKeys(approvals, ['responses'], 'P-14 approvals');
  if (!Array.isArray(approvals.responses) || approvals.responses.length !== 3) throw new Error('P-14 approval terminal states failed');
  const decisions = [];
  const approvalIDs = new Set();
  for (const response of approvals.responses) {
    exactKeys(response, ['approvalID', 'daemonApprovalID', 'invokedDecision', 'postResponsePhase', 'uiStatus'], 'P-14 approval response');
    if (!response.approvalID || approvalIDs.has(response.approvalID) || response.daemonApprovalID !== response.approvalID
        || response.uiStatus !== ({ approve: 'approved', reject: 'rejected', cancel: 'cancelled' })[response.invokedDecision]
        || (response.invokedDecision === 'approve' ? response.postResponsePhase !== 'completed' : response.postResponsePhase !== 'cancelled')) {
      throw new Error('P-14 approval daemon identity or terminal state failed');
    }
    approvalIDs.add(response.approvalID); decisions.push(response.invokedDecision);
  }
  if (JSON.stringify(decisions.sort()) !== JSON.stringify(['approve', 'cancel', 'reject'])) throw new Error('P-14 approval terminal states failed');
  const reconnect = map.get('reconnect-visibility');
  exactKeys(reconnect, ['afterMessageIDs', 'beforeMessageIDs', 'disconnectedHealth', 'disconnectedStatus', 'reconnectedHealth', 'reconnectedStatus', 'threadID'], 'P-14 reconnect');
  if (reconnect.disconnectedHealth !== false || reconnect.reconnectedHealth !== true || reconnect.threadID !== threadID
      || !/offline|unavailable|disconnected/iu.test(reconnect.disconnectedStatus)
      || !/connected|live daemon|resumed/iu.test(reconnect.reconnectedStatus)
      || JSON.stringify(reconnect.beforeMessageIDs) !== JSON.stringify(reconnect.afterMessageIDs)) throw new Error('P-14 reconnect/visibility recovery failed');
  const exported = map.get('export');
  exactKeys(exported, ['daemonMessageIDs', 'exportedMessageIDs', 'threadID'], 'P-14 export');
  if (exported.threadID !== threadID || exported.daemonMessageIDs.length < 2
      || JSON.stringify(exported.daemonMessageIDs) !== JSON.stringify(exported.exportedMessageIDs)) throw new Error('P-14 export identity is incomplete');
  const popout = map.get('popout');
  exactKeys(popout, ['afterCloseWindowIDs', 'first', 'primaryWindowID', 'second'], 'P-14 popout');
  exactKeys(popout.first, ['focusedWindowID', 'threadID', 'windowIDs'], 'P-14 first popout');
  exactKeys(popout.second, ['focusedWindowID', 'threadID', 'windowIDs'], 'P-14 second popout');
  if (popout.first.threadID !== threadID || popout.second.threadID !== threadID
      || popout.first.windowIDs.length !== 2 || JSON.stringify(popout.first.windowIDs) !== JSON.stringify(popout.second.windowIDs)
      || popout.first.focusedWindowID === popout.primaryWindowID || popout.second.focusedWindowID !== popout.first.focusedWindowID
      || JSON.stringify(popout.afterCloseWindowIDs) !== JSON.stringify([popout.primaryWindowID])) throw new Error('P-14 popout identity/focus/state preservation failed');
  const limitation = map.get('attachment-restart-limit');
  exactKeys(limitation, ['attachmentID', 'postRelaunchMetadataAttachmentID', 'registryFilePresentAfterRelaunch'], 'P-14 attachment restart limitation');
  if (limitation.attachmentID !== attachment.exportMetadata.attachmentId
      || limitation.postRelaunchMetadataAttachmentID !== limitation.attachmentID
      || limitation.registryFilePresentAfterRelaunch !== false) throw new Error('P-14 attachment restart limitation is dishonest');
}
function noLeak(value, label) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  if (/data:.*;base64|file:\/\/|\/(?:home|Users|tmp)\/|rawBytes|absolutePath/iu.test(text)) throw new Error(`${label} leaks raw attachment data or paths`);
}
export function validateP14InstalledSession(document, binding, { repoRoot = binding.repoRoot } = {}) {
  exactKeys(document, ['candidate', 'capture', 'desktop', 'environmentId', 'evidence', 'id', 'package', 'requirementId', 'schemaVersion', 'sourceEvidence', 'targetHead', 'threadID'], 'P-14 session');
  if (document.schemaVersion !== 1 || document.id !== 'openburnbar-linux-p14-installed-chat-v1') throw new Error('P-14 session identity is invalid');
  const envelope = validateInstalledSessionEnvelope(document, { ...binding, repoRoot }, P14_REQUIREMENT_ID, 'P-14 session');
  sourceEvidence(repoRoot, document.sourceEvidence);
  if (!/^p14-thread-[a-f0-9-]{36}$/u.test(document.threadID)) throw new Error('P-14 thread identity is invalid');
  exactKeys(document.evidence, ['attachment', 'daemon', 'databaseHeader', 'databaseProbe', 'desktop', 'exportJson', 'exportMarkdown', 'windowEvents'], 'P-14 evidence');
  const records = [];
  const load = (field, mediaType = 'json', minimumBytes = 20) => {
    const record = document.evidence[field]; records.push(record);
    return validateArtifact(repoRoot, record, P14_REQUIREMENT_ID, document.environmentId, `P-14 ${field}`, { mediaType, minimumBytes });
  };
  const daemon = eventMap(parseJson(load('daemon').bytes, 'P-14 daemon'), REQUIRED_DAEMON, 'P-14 daemon', envelope.startedAt, envelope.endedAt);
  const desktop = eventMap(parseJson(load('desktop').bytes, 'P-14 desktop'), REQUIRED_UI, 'P-14 desktop', envelope.startedAt, envelope.endedAt);
  validateDaemon(daemon, document.threadID); validateUI(desktop, document.threadID);
  const db = parseJson(load('databaseProbe').bytes, 'P-14 database probe');
  exactKeys(db, ['integrityCheck', 'messageCount', 'producer', 'sqlCipher', 'threadCount'], 'P-14 database probe');
  if (db.producer !== 'openburnbar-p14-installed-database-probe-v1' || db.sqlCipher !== true || db.integrityCheck !== 'ok' || db.threadCount < 1 || db.messageCount < 2) throw new Error('P-14 encrypted database proof failed');
  if (db.messageCount !== daemon.get('post-restart').messageCount) throw new Error('P-14 database and restart counts disagree');
  const header = load('databaseHeader', null, 32).bytes;
  if (header.subarray(0, 16).toString('ascii') === 'SQLite format 3\0') throw new Error('P-14 database header is plaintext SQLite');
  const attachmentObservation = desktop.get('attachment');
  const attachment = load('attachment', null, 1);
  if (attachment.sha256 !== attachmentObservation.input.sha256 || attachment.size !== attachmentObservation.input.byteSize) throw new Error('P-14 attachment bytes changed');
  const exportedJSON = parseJson(load('exportJson').bytes, 'P-14 JSON export'); noLeak(exportedJSON, 'P-14 JSON export');
  exactKeys(exportedJSON, ['messages', 'thread', 'version'], 'P-14 JSON export');
  exactKeys(exportedJSON.thread, ['id', 'title'], 'P-14 JSON export thread');
  if (exportedJSON.version !== 1 || exportedJSON.thread.id !== document.threadID
      || !Array.isArray(exportedJSON.messages)
      || JSON.stringify(exportedJSON.messages.map((message) => message.id)) !== JSON.stringify(desktop.get('export').exportedMessageIDs)) {
    throw new Error('P-14 JSON export identity or count is invalid');
  }
  const attachmentRows = exportedJSON.messages.flatMap((message) => message.attachments ?? []);
  if (!attachmentRows.some((item) => item.sha256 === attachment.sha256 && item.byteSize === attachment.size)) {
    throw new Error('P-14 JSON export lost durable attachment metadata');
  }
  const markdown = load('exportMarkdown', null, 20).bytes.toString('utf8'); noLeak(markdown, 'P-14 Markdown export');
  if (!markdown.includes(document.threadID) || !markdown.includes(attachmentRows[0].fileName)) {
    throw new Error('P-14 Markdown export is incomplete');
  }
  const windows = parseJson(load('windowEvents').bytes, 'P-14 window events');
  exactKeys(windows, ['mainWindowSurvived', 'popoutWindowID', 'primaryWindowID', 'producer', 'singlePopout'], 'P-14 window events');
  if (windows.producer !== 'openburnbar-p14-installed-window-probe-v1' || windows.singlePopout !== true
      || windows.mainWindowSurvived !== true || !windows.primaryWindowID || !windows.popoutWindowID
      || windows.primaryWindowID === windows.popoutWindowID) throw new Error('P-14 popout window lifecycle is unproven');
  return { document, evidence: [...envelope.attestation, ...records], endedAt: envelope.endedAt };
}
export function buildP14Proof({ session, source, collectedAt }) { return { schemaVersion: 1, requirementId: P14_REQUIREMENT_ID, role: P14_PROOF_ROLE, environmentId: session.environmentId, targetHead: session.targetHead, candidate: session.candidate, packageVersion: session.package.version, collectedAt, source, claim: { passed: true, threadID: session.threadID, restartUploadBytesRequireReupload: true } }; }
export function validateP14Proof({ repoRoot, snapshot, ...binding }) {
  const proof = parseJson(snapshot.bytes, 'P-14 proof');
  exactKeys(proof, ['candidate', 'claim', 'collectedAt', 'environmentId', 'packageVersion', 'requirementId', 'role', 'schemaVersion', 'source', 'targetHead'], 'P-14 proof');
  if (proof.schemaVersion !== 1 || proof.role !== P14_PROOF_ROLE || proof.requirementId !== P14_REQUIREMENT_ID || proof.environmentId !== binding.environmentId || proof.targetHead !== binding.targetHead || proof.candidate.runId !== String(binding.candidateRunId) || proof.candidate.artifactDigest !== binding.candidateArtifactDigest || proof.packageVersion !== binding.packageVersion || proof.claim.passed !== true || proof.claim.restartUploadBytesRequireReupload !== true) throw new Error('P-14 proof binding or claim is invalid');
  const source = validateArtifact(repoRoot, proof.source, P14_REQUIREMENT_ID, proof.environmentId, 'P-14 source session', { mediaType: 'json', minimumBytes: 500 });
  const session = validateP14InstalledSession(parseJson(source.bytes, 'P-14 session'), { ...binding, repoRoot }, { repoRoot });
  validateCollectedAt(proof.collectedAt, session.endedAt);
  if (proof.claim.threadID !== session.document.threadID) throw new Error('P-14 proof thread changed');
  return { proof, source, evidence: session.evidence };
}
