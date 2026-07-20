import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { captureP14ChatProof } from './capture-p14-chat-proof.mjs';
import { canonicalJsonBytes, createInstalledManifest, signInstalledManifest } from './lib/linux-installed-manifest.mjs';
import { P14_PROOF_ROLE, P14_SOURCE_CONTRACTS, validateP14InstalledSession, validateP14Proof } from './lib/p14-chat-proof.mjs';
import { RELEASE_ARCHITECTURES, SUPPORT_ENVIRONMENTS, readRegularSnapshot } from './lib/product-proof-closure.mjs';
import { materializeP14ChatSession } from './materialize-p14-chat-session.mjs';
import { validateProductRequirement } from './product-validators/P-14.mjs';
import { runP14ChatSession } from './run-p14-chat-session.mjs';
import { runP14NativeChatProbes } from './run-p14-native-chat-probes.mjs';

const HEAD = 'a'.repeat(40);
const RUN_ID = '141414';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const VERSION = '1.2.3';
const THREAD_ID = 'p14-thread-123e4567-e89b-42d3-a456-426614174000';

function write(file, bytes, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  if (mode) fs.chmodSync(file, mode);
  return file;
}
function json(file, value) { return write(file, `${JSON.stringify(value, null, 2)}\n`); }
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return { path: path.relative(root, file).split(path.sep).join('/'),
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length };
}
function sourceTree(root) {
  const markers = {
    [P14_SOURCE_CONTRACTS[0]]: 'BurnBarChatThreadService appendMessage hasMoreBefore',
    [P14_SOURCE_CONTRACTS[1]]: 'chatThreadList chatMessageAppend',
    [P14_SOURCE_CONTRACTS[2]]: 'chatThreadList chatThreadGet',
    [P14_SOURCE_CONTRACTS[3]]: 'runChatQueryCommand chat threads',
    [P14_SOURCE_CONTRACTS[4]]: 'chat_attachment_upload gateway_chat_stream',
    [P14_SOURCE_CONTRACTS[5]]: 'loadOlderMessages respondToToolApproval',
    [P14_SOURCE_CONTRACTS[6]]: 'CHAT_HISTORY_MAX_MESSAGES attachmentId',
    [P14_SOURCE_CONTRACTS[7]]: 'openChatPopoutWindow closeChatPopoutWindow'
  };
  for (const source of P14_SOURCE_CONTRACTS) write(path.join(root, source), `${markers[source]}\n`);
}
function makeAttestation(root, manifestPath, signaturePath) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
  const privatePem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicPem = publicKey.export({ type: 'spki', format: 'pem' });
  write(path.join(root, 'packaging/linux/openburnbar-linux-ed25519.pub.pem'), publicPem);
  const item = (installedPath, bytes, mode) => ({ path: installedPath, type: 'file',
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'), size: bytes.length, mode, uid: 0, gid: 0 });
  const manifest = createInstalledManifest({ files: [
    item('/usr/bin/openburnbar-daemon', Buffer.from('daemon'), '0755'),
    item('/usr/bin/openburnbar-linux-desktop', Buffer.from('desktop'), '0755'),
    item('/usr/share/openburnbar/attestation/release-ed25519.pub.pem', publicPem, '0644')
  ], packageVersion: VERSION, gitCommit: HEAD, packageArchitecture: 'aarch64', packageFormat: 'deb',
  firebaseAppId: '1:123:web:linux' });
  const manifestBytes = canonicalJsonBytes(manifest);
  const signatureBytes = signInstalledManifest(manifestBytes, privatePem, publicPem);
  write(manifestPath, manifestBytes);
  write(signaturePath, signatureBytes);
  return { manifestSha256: crypto.createHash('sha256').update(manifestBytes).digest('hex'),
    manifestSignatureSha256: crypto.createHash('sha256').update(signatureBytes).digest('hex') };
}
function binding(value) {
  return { repoRoot: value.root, environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
    candidateArtifactDigest: DIGEST, packageVersion: VERSION, ...value.attestation };
}
function nativeEvidence(options) {
  const at = (offset) => new Date(Date.now() + offset).toISOString();
  const attachment = { attachmentId: 'p14-attachment', fileName: path.basename(options.attachmentPath),
    mimeType: 'text/plain', byteSize: options.attachmentByteSize, sha256: options.attachmentSha256 };
  const exported = { version: 1, thread: { id: options.threadID, title: 'P14 installed chat' }, messages: [
    { id: 'm1', role: 'user', content: options.searchMarker, attachments: [attachment] },
    { id: 'm2', role: 'assistant', content: 'Durable response' },
    { id: 'm3', role: 'user', content: 'Older' },
    { id: 'm4', role: 'assistant', content: 'Older response' },
    { id: 'm5', role: 'system', content: 'System' }
  ] };
  const messageIDs = exported.messages.map((message) => message.id);
  return {
    desktopTranscript: { producer: 'openburnbar-p14-installed-desktop-probe-v1', events: [
      { kind: 'model-thinking', at: at(1), data: { selectedModel: 'hermes-live', upstreamModel: 'hermes-live', selectedThinking: 'high', upstreamThinking: 'high', fixtureMode: false } },
      { kind: 'attachment', at: at(2), data: {
        chooserWindowID: 'chooser-1',
        input: { byteSize: attachment.byteSize, fileName: attachment.fileName, mimeType: attachment.mimeType, sha256: attachment.sha256 },
        exportMetadata: { ...attachment }, postRestartMetadata: { ...attachment },
        upstreamAttachment: { byteSize: attachment.byteSize, fileName: attachment.fileName, sha256: attachment.sha256 }
      } },
      { kind: 'citation', at: at(3), data: { activatedCitationID: 'citation-1', citedMessageID: 'm3', citedThreadID: options.threadID,
        loadedPageMessageIDs: ['m3', 'm4'], selectedThreadIDAfter: options.threadID, status: 'Cited source message opened.' } },
      { kind: 'approvals', at: at(4), data: { responses: [
        { approvalID: 'approval-1', daemonApprovalID: 'approval-1', invokedDecision: 'approve', postResponsePhase: 'completed', uiStatus: 'approved' },
        { approvalID: 'approval-2', daemonApprovalID: 'approval-2', invokedDecision: 'reject', postResponsePhase: 'cancelled', uiStatus: 'rejected' },
        { approvalID: 'approval-3', daemonApprovalID: 'approval-3', invokedDecision: 'cancel', postResponsePhase: 'cancelled', uiStatus: 'cancelled' }
      ] } },
      { kind: 'reconnect-visibility', at: at(5), data: { beforeMessageIDs: messageIDs, afterMessageIDs: messageIDs,
        disconnectedHealth: false, disconnectedStatus: 'Daemon offline', reconnectedHealth: true,
        reconnectedStatus: 'Connected to live daemon', threadID: options.threadID } },
      { kind: 'export', at: at(6), data: { daemonMessageIDs: messageIDs, exportedMessageIDs: messageIDs, threadID: options.threadID } },
      { kind: 'popout', at: at(7), data: { primaryWindowID: '100', first: { focusedWindowID: '101', threadID: options.threadID, windowIDs: ['100', '101'] },
        second: { focusedWindowID: '101', threadID: options.threadID, windowIDs: ['100', '101'] }, afterCloseWindowIDs: ['100'] } },
      { kind: 'attachment-restart-limit', at: at(8), data: { attachmentID: attachment.attachmentId,
        postRelaunchMetadataAttachmentID: attachment.attachmentId, registryFilePresentAfterRelaunch: false } }
    ] },
    exportJson: `${JSON.stringify(exported, null, 2)}\n`,
    exportMarkdown: `# P14 installed chat\n\nThread: ${options.threadID}\n\nAttachments:\n- ${attachment.fileName} (text/plain, 0.0 KB, sha256 ${attachment.sha256})\n`,
    windowEvents: { producer: 'openburnbar-p14-installed-window-probe-v1', singlePopout: true,
      mainWindowSurvived: true, primaryWindowID: '100', popoutWindowID: '101' }
  };
}
async function fixture() {
  const base = path.join(process.cwd(), '.tmp', 'p14-proof-tests');
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, 'case-'));
  sourceTree(root);
  const rawOutput = path.join(root, 'runner-raw');
  fs.mkdirSync(rawOutput, { mode: 0o700 });
  const tokenFile = write(path.join(root, 'daemon-token'), `${'d'.repeat(64)}\n`, 0o600);
  const attachmentPath = write(path.join(root, 'attachment.txt'), 'bounded P14 attachment\n', 0o600);
  const databasePath = write(path.join(root, 'openburnbar.sqlite'), crypto.randomBytes(128), 0o600);
  const manifestPath = path.join(root, 'installed-manifest.json');
  const signaturePath = path.join(root, 'installed-manifest.json.sig');
  const attestation = makeAttestation(root, manifestPath, signaturePath);
  const rows = [];
  let restarted = false;
  const rpcClient = async (method, params) => {
    if (method === 'daemon.chat.message.append') {
      const existing = rows.find((row) => row.id === params.messageID);
      if (!existing) rows.push({ id: params.messageID, threadID: params.threadID, role: params.role,
        content: params.content, timestamp: params.timestamp, backendID: params.backendID });
      return { result: { message: existing ?? rows.at(-1), inserted: !existing } };
    }
    if (method === 'daemon.chat.thread.list') {
      const matching = rows.some((row) => row.content.includes(params.query));
      return { result: { threads: matching ? [{ id: THREAD_ID, title: 'P14', preview: rows.at(-1).content,
        messageCount: rows.length, createdAt: rows[0].timestamp, updatedAt: rows.at(-1).timestamp,
        lastMessageAt: rows.at(-1).timestamp, backendID: 'hermes' }] : [] } };
    }
    let available = [...rows].sort((left, right) => left.timestamp.localeCompare(right.timestamp) || left.id.localeCompare(right.id));
    if (params.beforeTimestamp) available = available.filter((row) => row.timestamp < params.beforeTimestamp
      || (row.timestamp === params.beforeTimestamp && row.id < params.beforeMessageID));
    const messages = available.slice(-params.maxMessages);
    return { result: { thread: { id: THREAD_ID, title: 'P14', preview: rows.at(-1).content,
      messageCount: rows.length, createdAt: rows[0].timestamp, updatedAt: rows.at(-1).timestamp,
      lastMessageAt: rows.at(-1).timestamp, backendID: 'hermes' }, messages,
    hasMoreBefore: available.length > messages.length } };
  };
  const cliRunner = (args) => {
    assert(restarted, 'CLI readback must occur after restart');
    if (args[1] === 'threads') return { threads: [{ id: THREAD_ID }] };
    return { thread: { id: THREAD_ID }, messages: [...rows].sort((left, right) => left.timestamp.localeCompare(right.timestamp) || left.id.localeCompare(right.id)), hasMoreBefore: false };
  };
  const options = { rawOutputDir: rawOutput, databasePath, attachmentPath, socketPath: '/run/user/1000/openburnbar.sock', tokenFile,
    environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID, candidateArtifactDigest: DIGEST,
    packageVersion: VERSION, ...attestation, compositor: 'Mutter', backendID: 'Hermes', model: 'hermes-live', thinking: 'high',
    downloadDir: root, supportDir: root, threadID: THREAD_ID };
  const ran = await runP14ChatSession(options, { installedVerifier: () => ({}), rpcClient, cliRunner,
    restartDaemon: () => { restarted = true; }, nativeProbe: nativeEvidence });
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-14', ENVIRONMENT);
  fs.mkdirSync(inputRoot, { recursive: true });
  const materialized = materializeP14ChatSession({ outputRoot: inputRoot, rawEvidenceDir: ran.output,
    threadID: THREAD_ID, compositor: 'Mutter', ...binding({ root, attestation }) }, {
    installedVerifier: () => ({ contract: { architecture: 'aarch64', format: 'deb', desktop: 'gnome', session: 'x11' } }),
    manifestPath, signaturePath
  });
  return { root, inputRoot, rawOutput, materialized, attestation, manifestPath, signaturePath };
}
function context(value, proofFile) {
  const subjects = path.join(value.inputRoot, 'release-subjects');
  const aggregate = record(value.root, json(path.join(subjects, 'aggregate.json'), { passed: true }));
  const runtime = record(value.root, json(path.join(subjects, 'runtime.json'), { shellVersion: VERSION, daemonVersion: VERSION }));
  const environment = record(value.root, json(path.join(subjects, 'environment.json'), { environmentId: ENVIRONMENT, targetHead: HEAD, architecture: 'aarch64', passed: true }));
  const pkg = record(value.root, write(path.join(subjects, 'package.deb'), 'deb\n'));
  const proof = record(value.root, proofFile);
  return { schemaVersion: 1, repoRoot: value.root, requirementId: 'P-14', checkId: 'p-14.chat', environmentId: ENVIRONMENT, targetHead: HEAD,
    releaseClosure: { document: { schemaVersion: 3, targetHead: HEAD, sourceCommit: HEAD, status: 'passed', requirementId: 'P-14', environmentId: ENVIRONMENT,
      version: VERSION, blockers: [], architectures: [...RELEASE_ARCHITECTURES], supportEnvironments: [...SUPPORT_ENVIRONMENTS],
      selectedPackage: { architecture: 'aarch64', format: 'deb' }, candidate: { runId: RUN_ID, artifactDigest: DIGEST },
      packageManifestSignature: value.materialized.document.package.signature,
      proofs: [{ role: 'aggregate-product-proof-closure', ...aggregate }, { role: P14_PROOF_ROLE, ...proof }] } },
    subjects: { release: aggregate, packageManifest: value.materialized.document.package.manifest, packages: [pkg],
      runtimes: [runtime], installation: [aggregate], environment, features: [] } };
}

test('P-14 runner, materializer, capture, and product validator close one signed installed chat session', async () => {
  const value = await fixture();
  try {
    const captured = captureP14ChatProof({ inputRoot: value.inputRoot, sessionReport: value.materialized.output,
      ...binding(value), resolveHead: () => HEAD, now: () => new Date(Date.now() + 100) });
    const validated = validateP14Proof({ repoRoot: value.root,
      snapshot: readRegularSnapshot(value.root, path.relative(value.root, captured.output), 'P-14 proof'), ...binding(value) });
    assert.equal(validated.proof.claim.restartUploadBytesRequireReupload, true);
    assert.equal(validated.evidence.length, 10);
    assert.equal((await validateProductRequirement(context(value, captured.output))).status, 'passed');
  } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
});

test('P-14 independently rejects semantic mutations, changed bytes, source drift, and forged signatures', async () => {
  const cases = [
    ['duplicate accepted', (value, doc) => mutate(value, doc.evidence.daemon, (payload) => { payload.events.find((event) => event.kind === 'append-duplicate').data.inserted = true; }), /idempotent/u],
    ['unstable pagination', (value, doc) => mutate(value, doc.evidence.daemon, (payload) => { payload.events.find((event) => event.kind === 'pagination').data.cursorStable = false; }), /pagination/u],
    ['wrong model', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'model-thinking').data.upstreamModel = 'other'; }), /model/u],
    ['attachment hash mismatch', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'attachment').data.exportMetadata.sha256 = 'f'.repeat(64); }), /attachment/u],
    ['upstream attachment mismatch', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'attachment').data.upstreamAttachment.sha256 = 'e'.repeat(64); }), /attachment/u],
    ['citation thread mismatch', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'citation').data.selectedThreadIDAfter = 'other'; }), /citation/u],
    ['approval identity mismatch', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'approvals').data.responses[0].daemonApprovalID = 'other'; }), /approval/u],
    ['approval phase mismatch', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'approvals').data.responses[0].postResponsePhase = 'cancelled'; }), /approval/u],
    ['reconnect was not interrupted', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'reconnect-visibility').data.disconnectedHealth = true; }), /reconnect/u],
    ['export missing message', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'export').data.exportedMessageIDs.pop(); }), /export/u],
    ['popout refocused primary', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'popout').data.second.focusedWindowID = '100'; }), /popout/u],
    ['raw bytes claimed durable', (value, doc) => mutate(value, doc.evidence.desktop, (payload) => { payload.events.find((event) => event.kind === 'attachment-restart-limit').data.registryFilePresentAfterRelaunch = true; }), /limitation/u],
    ['plaintext database', (value, doc) => { const file = path.join(value.root, doc.evidence.databaseHeader.path); fs.writeFileSync(file, Buffer.concat([Buffer.from('SQLite format 3\0'), Buffer.alloc(16)])); doc.evidence.databaseHeader = record(value.root, file); }, /plaintext/u],
    ['export path leak', (value, doc) => mutate(value, doc.evidence.exportJson, (payload) => { payload.messages[0].content = '/home/user/private'; }), /leaks/u],
    ['source drift', (value, doc) => { fs.appendFileSync(path.join(value.root, doc.sourceEvidence[0].path), 'drift\n'); }, /source changed/u]
  ];
  for (const [label, change, pattern] of cases) {
    const value = await fixture();
    try {
      const doc = structuredClone(value.materialized.document); change(value, doc);
      assert.throws(() => validateP14InstalledSession(doc, binding(value), { repoRoot: value.root }), pattern, label);
    } finally { fs.rmSync(value.root, { recursive: true, force: true }); }
  }
  const forged = await fixture();
  try {
    const doc = structuredClone(forged.materialized.document);
    const file = path.join(forged.root, doc.package.signature.path);
    fs.writeFileSync(file, Buffer.alloc(64, 7)); doc.package.signature = record(forged.root, file);
    assert.throws(() => validateP14InstalledSession(doc, { ...binding(forged), manifestSignatureSha256: doc.package.signature.sha256 }, { repoRoot: forged.root }), /signature/u);
  } finally { fs.rmSync(forged.root, { recursive: true, force: true }); }
  const changed = await fixture();
  try {
    fs.appendFileSync(path.join(changed.root, changed.materialized.document.evidence.attachment.path), 'changed');
    assert.throws(() => validateP14InstalledSession(changed.materialized.document, binding(changed), { repoRoot: changed.root }), /bytes changed/u);
  } finally { fs.rmSync(changed.root, { recursive: true, force: true }); }
  const stale = await fixture();
  try {
    const endedAt = Date.parse(stale.materialized.document.capture.endedAt);
    assert.throws(() => captureP14ChatProof({ inputRoot: stale.inputRoot, sessionReport: stale.materialized.output,
      ...binding(stale), resolveHead: () => HEAD, now: () => new Date(endedAt + 20 * 60_000) }), /stale/u);
  } finally { fs.rmSync(stale.root, { recursive: true, force: true }); }
});

test('P-14 live runner fails closed on duplicate acceptance and native UI failure', async () => {
  for (const mode of ['duplicate', 'native']) {
    const root = fs.mkdtempSync(path.join(process.cwd(), '.tmp/p14-proof-tests/failure-'));
    try {
      const rawOutputDir = path.join(root, 'raw'); fs.mkdirSync(rawOutputDir, { mode: 0o700 });
      const tokenFile = write(path.join(root, 'token'), `${'e'.repeat(64)}\n`, 0o600);
      const attachmentPath = write(path.join(root, 'attachment.txt'), 'attachment\n', 0o600);
      const databasePath = write(path.join(root, 'db'), crypto.randomBytes(64), 0o600);
      let calls = 0;
      await assert.rejects(() => runP14ChatSession({ rawOutputDir, tokenFile, attachmentPath, databasePath,
        socketPath: '/tmp/p14.sock', supportDir: root, environmentId: ENVIRONMENT, targetHead: HEAD, candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST, packageVersion: VERSION, manifestSha256: '1'.repeat(64),
        manifestSignatureSha256: '2'.repeat(64), backendID: 'Hermes', model: 'model', thinking: 'high', downloadDir: root }, {
        installedVerifier: () => ({}), rpcClient: async () => ({ result: { inserted: calls++ === 0 || mode === 'duplicate', message: { id: calls === 1 ? undefined : 'wrong' } } }),
        nativeProbe: async () => { throw new Error('native AT-SPI failure'); }
      }), mode === 'duplicate' ? /first append|idempotent/u : /first append|native/u);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});

test('P-14 native probe refuses to claim X11-equivalent evidence on Wayland', async () => {
  await assert.rejects(() => runP14NativeChatProbes({ environmentId: 'ubuntu-24.04-gnome-wayland-aarch64' },
    { platform: 'linux' }), /Wayland/u);
});

function mutate(value, artifact, update) {
  const file = path.join(value.root, artifact.path);
  const payload = JSON.parse(fs.readFileSync(file, 'utf8')); update(payload); json(file, payload);
  Object.assign(artifact, record(value.root, file));
}
