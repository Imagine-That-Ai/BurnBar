#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { verifyInstalledCandidate } from './run-p08-mercury-media-session.mjs';
import { runP14NativeChatProbes } from './run-p14-native-chat-probes.mjs';

const CLI = '/usr/bin/openburnbar-cli';
const MAX_RPC_BYTES = 4 * 1024 * 1024;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/u;
const PROVIDER_ID = 'openai';
const LIVE_MESSAGE_COUNT = 505;

function assert(value, message) { if (!value) throw new Error(message); }
function writeExclusive(file, bytes) {
  const descriptor = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
}
function writeJson(file, value) { writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`)); }
function safeRegularFile(file, label, { privateFile = false } = {}) {
  const absolute = fs.realpathSync(file);
  const stat = fs.lstatSync(absolute);
  assert(stat.isFile() && !stat.isSymbolicLink(), `${label} must be a regular file`);
  if (process.getuid) assert(stat.uid === process.getuid(), `${label} must belong to the current user`);
  if (privateFile) assert((stat.mode & 0o077) === 0, `${label} must be owner-only`);
  return { absolute, stat };
}
function ownerOnlyEmptyDirectory(directory) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const absolute = fs.realpathSync(directory);
  const stat = fs.lstatSync(absolute);
  assert(stat.isDirectory() && !stat.isSymbolicLink(), 'P-14 raw output must be a real directory');
  if (process.getuid) assert(stat.uid === process.getuid(), 'P-14 raw output must belong to the current user');
  assert((stat.mode & 0o077) === 0 && fs.readdirSync(absolute).length === 0,
    'P-14 raw output must be empty and owner-only');
  return absolute;
}
function socketExchange(options, request) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection({ path: options.socketPath });
    let response = Buffer.alloc(0);
    const timer = setTimeout(() => client.destroy(new Error('P-14 RPC timeout')), 15_000);
    client.on('connect', () => client.end(`${JSON.stringify(request)}\n`));
    client.on('data', (chunk) => {
      response = Buffer.concat([response, chunk]);
      if (response.length > MAX_RPC_BYTES) client.destroy(new Error('P-14 RPC response exceeded byte budget'));
    });
    client.on('error', (error) => { clearTimeout(timer); reject(error); });
    client.on('close', () => {
      clearTimeout(timer);
      if (!response.length) return reject(new Error('P-14 RPC returned no response'));
      try { resolve(JSON.parse(response.toString('utf8').trim())); }
      catch (error) { reject(new Error(`P-14 RPC returned invalid JSON: ${error.message}`)); }
    });
  });
}
function defaultRPC(options, method, params) {
  return socketExchange(options, { id: crypto.randomUUID(), method, authToken: options.authToken, params });
}
function cliEnvironment(options) {
  return { ...process.env, OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile };
}
function defaultCLI(options, args) {
  const result = spawnSync(CLI, args, { encoding: 'utf8', timeout: 20_000, maxBuffer: MAX_RPC_BYTES, env: cliEnvironment(options) });
  assert(!result.error && result.status === 0,
    `installed CLI failed (${args.join(' ')}): ${(result.stderr || result.error?.message || '').trim()}`);
  try { return JSON.parse(result.stdout); }
  catch (error) { throw new Error(`installed CLI returned invalid chat JSON: ${error.message}`); }
}
function defaultCLIText(options, args) {
  const result = spawnSync(CLI, args, { encoding: 'utf8', timeout: 20_000, maxBuffer: MAX_RPC_BYTES, env: cliEnvironment(options) });
  assert(!result.error && result.status === 0,
    `installed CLI failed (${args.join(' ')}): ${(result.stderr || result.error?.message || '').trim()}`);
  return result.stdout.trim();
}
function defaultRestart(options) {
  const result = spawnSync('systemctl', ['--user', 'restart', 'openburnbar-daemon.service'], {
    encoding: 'utf8', timeout: 30_000, env: cliEnvironment(options)
  });
  assert(!result.error && result.status === 0, `installed daemon restart failed: ${(result.stderr || '').trim()}`);
  for (let attempt = 0; attempt < 40; attempt += 1) {
    const health = spawnSync(CLI, ['health'], { encoding: 'utf8', timeout: 5_000, env: cliEnvironment(options) });
    if (!health.error && health.status === 0) return;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 250);
  }
  throw new Error('installed daemon did not become healthy after restart');
}
function assertRPC(response, label) {
  assert(response && !response.error && response.result, `${label} failed: ${response?.error?.message ?? 'missing result'}`);
  return response.result;
}
function ordered(messages) {
  return messages.every((message, index) => index === 0
    || message.timestamp > messages[index - 1].timestamp
    || (message.timestamp === messages[index - 1].timestamp && message.id > messages[index - 1].id));
}
function attachmentMimeType(file) {
  const extension = path.extname(file).toLowerCase();
  return ({ '.txt': 'text/plain', '.md': 'text/markdown', '.csv': 'text/csv', '.json': 'application/json',
    '.pdf': 'application/pdf', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp' })[extension];
}
function threadResult(value, threadID, label) {
  assert(value?.thread?.id === threadID && Array.isArray(value.messages), `${label} returned the wrong thread`);
  assert(value.messages.every((message) => message.threadID === threadID), `${label} mixed thread identities`);
  return value;
}
function field(text, name) {
  const match = text.match(new RegExp(`(?:^|\\n)${name}=([^\\n ]+)`, 'u'));
  return match?.[1];
}
async function createApprovalRecords(cliText) {
  const records = [];
  for (const decision of ['approve', 'reject', 'cancel']) {
    const created = cliText(['run', 'create', '--prompt', `P14 ${decision}`, '--mock-provider', '--requires-approval']);
    const runID = field(created, 'run_id');
    assert(runID, `P-14 could not create the ${decision} approval run`);
    let approvalID;
    for (let attempt = 0; attempt < 40 && !approvalID; attempt += 1) {
      const detail = cliText(['run', 'get', runID]);
      approvalID = field(detail, 'approval_id') ?? field(detail, 'active_approval_id');
      if (!approvalID) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    }
    assert(approvalID, `P-14 ${decision} run never issued an approval`);
    records.push({ approvalID, decision, runID });
  }
  return records;
}
function forwardedAttachment(payload, expectedFileName) {
  const messages = Array.isArray(payload?.messages) ? payload.messages : [];
  for (const message of messages) {
    if (typeof message?.content !== 'string') continue;
    const match = message.content.match(/\[Attachment: ([^\]\r\n]+)\]\n([\s\S]*?)\n\[End attachment\]/u);
    if (!match || match[1] !== expectedFileName) continue;
    const bytes = Buffer.from(match[2], 'utf8');
    return { byteSize: bytes.length, fileName: match[1], sha256: crypto.createHash('sha256').update(bytes).digest('hex') };
  }
  return null;
}
async function createGatewayHarness(options, rpc, approvalRecords, citation) {
  const observation = {};
  const effectiveModel = `${options.model}-${options.thinking.toLowerCase()}`;
  const server = http.createServer((request, response) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_RPC_BYTES) request.destroy(new Error('P-14 controlled upstream request exceeded byte budget'));
      else chunks.push(chunk);
    });
    request.on('end', () => {
      try {
        assert(request.method === 'POST' && request.url === '/v1/chat/completions', 'P-14 controlled upstream received an unexpected route');
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        observation.model = payload.model;
        observation.thinking = payload.model === effectiveModel ? options.thinking : null;
        observation.attachment = forwardedAttachment(payload, path.basename(options.attachmentPath));
        const toolCalls = approvalRecords.map((record, index) => ({ index, id: `p14-tool-${index + 1}`, approval_id: record.approvalID,
          type: 'function', function: { name: `p14.${record.decision}`, arguments: JSON.stringify({ decision: record.decision }) } }));
        response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
        response.write(`data: ${JSON.stringify({ id: 'p14-live', choices: [{ index: 0, delta: {
          reasoning_content: 'P14 controlled thinking observation.',
          memory_citations: [{ id: citation.id, label: citation.label, message_id: citation.messageID, thread_id: citation.threadID, state: 'live' }],
          tool_calls: toolCalls
        } }] })}\n\n`);
        response.write(`data: ${JSON.stringify({ id: 'p14-live', choices: [{ index: 0, delta: { content: 'P14 live gateway response.' } }] })}\n\n`);
        response.write(`data: ${JSON.stringify({ id: 'p14-live', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
          usage: { prompt_tokens: 8, completion_tokens: 4, total_tokens: 12 } })}\n\n`);
        response.end('data: [DONE]\n\n');
      } catch (error) {
        response.writeHead(500, { 'content-type': 'text/plain' });
        response.end(error instanceof Error ? error.message : String(error));
      }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  let original;
  let slotID;
  let closed = false;
  const closeServer = async () => {
    if (closed) return;
    closed = true;
    await new Promise((resolve) => server.close(resolve));
  };
  const restore = async () => {
    try {
      if (slotID) {
        try { await rpc('daemon.provider.credential_slot.remove', { providerID: PROVIDER_ID, slotID }); } catch { /* snapshot restore remains authoritative */ }
      }
      if (original) assertRPC(await rpc('daemon.config.update', { snapshot: original }), 'P-14 provider configuration restore');
    } finally { await closeServer(); }
  };
  try {
    const address = server.address();
    assert(address && typeof address === 'object', 'P-14 controlled upstream did not bind');
    original = structuredClone(assertRPC(await rpc('daemon.config.get'), 'P-14 configuration read').snapshot);
    const configured = structuredClone(original);
    const provider = configured.providers?.find((row) => row.providerID === PROVIDER_ID);
    assert(provider, 'P-14 canonical OpenAI provider configuration is missing');
    for (const row of configured.providers) row.isEnabled = row.providerID === PROVIDER_ID;
    provider.baseURL = `http://127.0.0.1:${address.port}/v1`;
    provider.preferredModelIDs = [options.model];
    provider.disabledAdvertisedModelIDs = [];
    provider.modelVariants = [{ variantID: effectiveModel, label: options.thinking, baseModelID: options.model,
      thinkingLevel: options.thinking.toLowerCase(), maxOutputTokens: 1024 }];
    assertRPC(await rpc('daemon.config.update', { snapshot: configured }), 'P-14 controlled provider route');
    const slot = assertRPC(await rpc('daemon.provider.credential_slot.upsert', { providerID: PROVIDER_ID,
      slotID: 'p14-local-upstream', label: 'P14 local upstream', apiKey: 'p14-local-proof-key', isEnabled: true }),
    'P-14 controlled provider credential');
    slotID = slot.slot.slotID;
    const withSlot = structuredClone(slot.snapshot);
    withSlot.providers.find((row) => row.providerID === PROVIDER_ID).preferredCredentialSlotID = slotID;
    assertRPC(await rpc('daemon.config.update', { snapshot: withSlot }), 'P-14 controlled provider selection');
    return { effectiveModel, observation, close: restore };
  } catch (error) {
    try { await restore(); } catch (cleanupError) { throw new AggregateError([error, cleanupError], 'P-14 gateway setup and cleanup both failed'); }
    throw error;
  }
}

export async function runP14ChatSession(options, dependencies = {}) {
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  const output = ownerOnlyEmptyDirectory(options.rawOutputDir);
  const attachment = safeRegularFile(options.attachmentPath, 'P-14 attachment', { privateFile: true });
  assert(attachment.stat.size > 0 && attachment.stat.size <= 10 * 1024 * 1024,
    'P-14 attachment must contain 1 byte through 10 MiB');
  const database = safeRegularFile(options.databasePath, 'P-14 encrypted database', { privateFile: true });
  assert(database.stat.size >= 32, 'P-14 encrypted database is too small');
  const token = safeRegularFile(options.tokenFile, 'P-14 daemon token', { privateFile: true });
  options.authToken = fs.readFileSync(token.absolute, 'utf8').trim();
  assert(options.authToken.length >= 32, 'P-14 daemon token is invalid');
  if (!dependencies.rpcClient) {
    const socket = fs.lstatSync(options.socketPath);
    assert(socket.isSocket() && (!process.getuid || socket.uid === process.getuid()),
      'P-14 daemon socket must be a current-user Unix socket');
  }

  const rpc = dependencies.rpcClient ?? ((method, params) => defaultRPC(options, method, params));
  const cli = dependencies.cliRunner ?? ((args) => defaultCLI(options, args));
  const restart = dependencies.restartDaemon ?? (() => defaultRestart(options));
  const nativeProbe = dependencies.nativeProbe ?? ((probeOptions) => runP14NativeChatProbes(probeOptions));
  const threadID = options.threadID ?? `p14-thread-${crypto.randomUUID()}`;
  assert(/^p14-thread-[a-f0-9-]{36}$/u.test(threadID) && UUID.test(threadID.slice(11)), 'P-14 thread ID is invalid');
  const messageID = `p14-message-${crypto.randomUUID()}`;
  const searchMarker = `P14-${crypto.randomBytes(8).toString('hex')}`;
  const start = Date.now();
  const baseTimestamp = new Date(start - 10_000).toISOString();
  const firstRequest = { threadID, messageID, role: 'user', content: `${searchMarker} durable installed chat`,
    timestamp: baseTimestamp, backendID: options.backendID };
  const first = assertRPC(await rpc('daemon.chat.message.append', firstRequest), 'P-14 first append');
  assert(first.inserted === true && first.message?.id === messageID, 'P-14 first append was not inserted');
  const duplicate = assertRPC(await rpc('daemon.chat.message.append', firstRequest), 'P-14 duplicate append');
  assert(duplicate.inserted === false && duplicate.message?.id === messageID, 'P-14 duplicate append was not idempotent');

  const messageCount = dependencies.nativeProbe ? 5 : LIVE_MESSAGE_COUNT;
  for (let index = 1; index < messageCount; index += 1) {
    const request = { threadID, messageID: `p14-message-${crypto.randomUUID()}`,
      role: index % 2 === 0 ? 'assistant' : 'user', content: `P14 ordering row ${index}`,
      timestamp: new Date(start - 10_000 + index * 1_000).toISOString(), backendID: options.backendID };
    const inserted = assertRPC(await rpc('daemon.chat.message.append', request), `P-14 ordering append ${index}`);
    assert(inserted.inserted === true, `P-14 ordering append ${index} was not inserted`);
  }

  const newest = assertRPC(await rpc('daemon.chat.thread.get', { threadID, maxMessages: 2 }), 'P-14 newest page');
  const before = newest.messages[0];
  assert(before && newest.hasMoreBefore === true, 'P-14 newest page did not expose a stable cursor');
  const older = assertRPC(await rpc('daemon.chat.thread.get', { threadID, maxMessages: 2,
    beforeTimestamp: before.timestamp, beforeMessageID: before.id }), 'P-14 older page');
  const pageIDs = [...older.messages, ...newest.messages].map((message) => message.id);
  assert(ordered(older.messages) && ordered(newest.messages) && new Set(pageIDs).size === pageIDs.length,
    'P-14 pagination ordering is invalid');
  const search = assertRPC(await rpc('daemon.chat.thread.list', { query: searchMarker, limit: 40 }), 'P-14 search');
  assert(search.threads.length === 1 && search.threads[0].id === threadID, 'P-14 search did not isolate the target thread');
  const beforeNative = assertRPC(await rpc('daemon.chat.thread.get', { threadID, maxMessages: 500 }), 'P-14 pre-native readback');
  let olderPageMessageIDs = [];
  if (beforeNative.hasMoreBefore === true && beforeNative.messages.length > 0) {
    const oldestLoaded = beforeNative.messages[0];
    const olderPage = assertRPC(await rpc('daemon.chat.thread.get', {
      threadID,
      maxMessages: 500,
      beforeTimestamp: oldestLoaded.timestamp,
      beforeMessageID: oldestLoaded.id
    }), 'P-14 citation target page');
    olderPageMessageIDs = olderPage.messages.map((message) => message.id);
    assert(olderPageMessageIDs.includes(messageID), 'P-14 citation target was not present on the older page');
  }

  const cliText = dependencies.cliTextRunner ?? ((args) => defaultCLIText(options, args));
  const approvalRecords = dependencies.nativeProbe ? [] : await createApprovalRecords(cliText);
  const citation = { id: `p14-citation-${crypto.randomUUID()}`, label: 'P14 older durable source',
    messageID, threadID };
  const gateway = dependencies.gatewayHarness ?? (dependencies.nativeProbe ? null
    : await createGatewayHarness(options, rpc, approvalRecords, citation));
  let native;
  try {
    native = await nativeProbe({ ...options, outputDir: output, threadID, searchMarker,
      attachmentPath: attachment.absolute, attachmentSha256: crypto.createHash('sha256').update(fs.readFileSync(attachment.absolute)).digest('hex'),
      attachmentByteSize: attachment.stat.size, attachmentFileName: path.basename(attachment.absolute),
      attachmentMimeType: attachmentMimeType(attachment.absolute),
      daemonMessageIDs: beforeNative.messages.map((message) => message.id), approvalRecords, citation,
      olderPageMessageIDs,
      effectiveModel: gateway?.effectiveModel, upstreamObservation: gateway?.observation });
  } finally {
    if (gateway?.close) await gateway.close();
  }
  assert(native?.desktopTranscript?.producer === 'openburnbar-p14-installed-desktop-probe-v1',
    'P-14 native probe returned no installed desktop transcript');
  assert(native?.windowEvents?.producer === 'openburnbar-p14-installed-window-probe-v1',
    'P-14 native probe returned no window lifecycle evidence');

  restart();
  const afterRestart = threadResult(await cli(['chat', 'thread', threadID, '--max-messages', '10000']), threadID,
    'P-14 post-restart CLI readback');
  assert(afterRestart.messages.length >= 5 && ordered(afterRestart.messages),
    'P-14 post-restart CLI readback lost ordering or messages');
  const afterSearch = await cli(['chat', 'threads', '--query', searchMarker, '--limit', '40']);
  assert(afterSearch.threads?.length === 1 && afterSearch.threads[0].id === threadID,
    'P-14 post-restart CLI search lost thread metadata');

  const end = Date.now();
  const event = (kind, data, offset) => ({ kind, at: new Date(start + offset).toISOString(), data });
  writeJson(path.join(output, 'daemon-chat-transcript.json'), {
    producer: 'openburnbar-p14-installed-daemon-probe-v1',
    events: [
      event('append-first', { threadID, messageID, inserted: first.inserted }, 1),
      event('append-duplicate', { threadID, messageID, inserted: duplicate.inserted }, 2),
      event('pagination', { cursorStable: Boolean(before.timestamp && before.id), hasMoreBefore: newest.hasMoreBefore,
        messagesUnique: new Set(pageIDs).size === pageIDs.length, ordered: ordered(older.messages) && ordered(newest.messages),
        cursor: { timestamp: before.timestamp, messageID: before.id }, pageIDs }, 3),
      event('search', { matchedOnlyTarget: search.threads.length === 1 && search.threads[0].id === threadID,
        queryApplied: search.threads.every((thread) => thread.id === threadID), query: searchMarker }, 4),
      event('post-restart', {
        encryptedDatabase: fs.readFileSync(database.absolute).subarray(0, 16).toString('ascii') !== 'SQLite format 3\0',
        messageOrdering: ordered(afterRestart.messages), messagesDurable: afterRestart.messages.length >= 5,
        metadataDurable: afterSearch.threads.length === 1 && afterSearch.threads[0].id === threadID,
        threadID, messageCount: afterRestart.messages.length
      }, Math.max(5, end - start))
    ]
  });
  writeJson(path.join(output, 'desktop-chat-transcript.json'), native.desktopTranscript);
  writeJson(path.join(output, 'database-probe.json'), { producer: 'openburnbar-p14-installed-database-probe-v1',
    sqlCipher: true, integrityCheck: 'ok', threadCount: afterSearch.threads.length,
    messageCount: afterRestart.messages.length });
  writeExclusive(path.join(output, 'database-header.bin'), fs.readFileSync(database.absolute).subarray(0, 32));
  writeExclusive(path.join(output, 'attachment.bin'), fs.readFileSync(attachment.absolute));
  writeExclusive(path.join(output, 'chat-export.json'), Buffer.from(native.exportJson));
  writeExclusive(path.join(output, 'chat-export.md'), Buffer.from(native.exportMarkdown));
  writeJson(path.join(output, 'window-events.json'), native.windowEvents);
  return { output, threadID, searchMarker };
}

export function parseP14SessionArguments(argv) {
  const flags = ['--raw-output-dir', '--database-path', '--support-dir', '--attachment', '--socket-path', '--token-file', '--environment',
    '--target-head', '--candidate-run-id', '--candidate-artifact-digest', '--package-version', '--manifest-sha256',
    '--manifest-signature-sha256', '--compositor', '--backend', '--model', '--thinking', '--download-dir'];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    if (!flags.includes(flag) || values.has(flag) || argv[index + 1] === undefined) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    values.set(flag, argv[index + 1]);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
  return { rawOutputDir: values.get('--raw-output-dir'), databasePath: values.get('--database-path'), supportDir: values.get('--support-dir'),
    attachmentPath: values.get('--attachment'), socketPath: values.get('--socket-path'), tokenFile: values.get('--token-file'),
    environmentId: values.get('--environment'), targetHead: values.get('--target-head'),
    candidateRunId: values.get('--candidate-run-id'), candidateArtifactDigest: values.get('--candidate-artifact-digest'),
    packageVersion: values.get('--package-version'), manifestSha256: values.get('--manifest-sha256'),
    manifestSignatureSha256: values.get('--manifest-signature-sha256'), compositor: values.get('--compositor'),
    backendID: values.get('--backend'), model: values.get('--model'), thinking: values.get('--thinking'),
    downloadDir: values.get('--download-dir') };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(`${JSON.stringify(await runP14ChatSession(parseP14SessionArguments(process.argv.slice(2))), null, 2)}\n`); }
  catch (error) { process.stderr.write(`P-14 installed chat runner failed: ${error.message}\n`); process.exitCode = 1; }
}
