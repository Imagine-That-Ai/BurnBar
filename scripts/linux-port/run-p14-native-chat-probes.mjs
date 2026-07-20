#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { INSTALLED_UI_ENVIRONMENTS } from './lib/installed-ui-proof.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DESKTOP = '/usr/bin/openburnbar-linux-desktop';
const CLI = '/usr/bin/openburnbar-cli';
const CONTROL = path.join(ROOT, 'scripts/linux-port/p14-atspi-control.py');

function assert(value, message) { if (!value) throw new Error(message); }
function sleep(ms) { return new Promise((resolve) => setTimeout(resolve, ms)); }
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 20_000, maxBuffer: 4 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed: ${(result.stderr || result.error?.message || '').trim()}`);
  return result.stdout.trim();
}
function commandExists(command) { run('sh', ['-c', 'command -v "$1" >/dev/null', 'p14-tool', command]); }
function startApp(outputDir, environment = {}) {
  const child = spawn(DESKTOP, [], { stdio: ['ignore', 'ignore', 'ignore'],
    env: { ...process.env, ...environment, OPENBURNBAR_EVIDENCE_OUT: outputDir } });
  child.unref();
  return child;
}
async function waitFor(label, callback, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    try { return callback(); } catch (error) { last = error; await sleep(250); }
  }
  throw new Error(`${label} timed out: ${last?.message ?? 'unavailable'}`);
}
function windowIDs(pid) {
  return run('xdotool', ['search', '--pid', String(pid)]).split(/\s+/u).filter(Boolean);
}
function installedDesktopPIDs() {
  const result = spawnSync('pgrep', ['-f', '^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)'], { encoding: 'utf8' });
  if (result.status === 1) return [];
  assert(!result.error && result.status === 0, `P-14 desktop process preflight failed: ${(result.stderr || '').trim()}`);
  return result.stdout.trim().split(/\s+/u).filter(Boolean).map(Number).filter(Number.isSafeInteger);
}
function safeDirectory(directory, label) {
  const absolute = fs.realpathSync(directory);
  const stat = fs.lstatSync(absolute);
  assert(stat.isDirectory() && !stat.isSymbolicLink(), `${label} must be a real directory`);
  if (process.getuid) assert(stat.uid === process.getuid(), `${label} must belong to the current user`);
  return absolute;
}
async function waitForExit(pid) {
  await waitFor(`installed desktop PID ${pid} exit`, () => {
    const result = spawnSync('kill', ['-0', String(pid)]); assert(result.status !== 0, `PID ${pid} is still running`); return true;
  }, 15_000);
}
function control(outputDir, suffix, mode, name, extra = []) {
  const output = path.join(outputDir, `p14-atspi-${suffix}.json`);
  const args = [CONTROL, '--application', 'OpenBurnBar', '--mode', mode, '--output', output];
  if (name) args.push('--name', name);
  args.push(...extra);
  run('python3', args);
  return JSON.parse(fs.readFileSync(output, 'utf8'));
}
function snapshot(outputDir, suffix) { return control(outputDir, suffix, 'snapshot'); }
function activate(outputDir, suffix, name) { return control(outputDir, suffix, 'activate', name); }
function setText(outputDir, suffix, name, value) {
  return control(outputDir, suffix, 'set-text', name, ['--text', value]);
}
function select(outputDir, suffix, name, option) {
  return control(outputDir, suffix, 'select', name, ['--option', option]);
}
function names(tree) { return tree.nodes.map((node) => node.name).filter(Boolean); }
function contains(tree, pattern) { return names(tree).some((name) => pattern.test(name)); }
function selected(tree, expected) {
  return tree.nodes.some((node) => node.name === expected && node.states.includes('selected'));
}
function newestFile(directory, extension, afterMs) {
  const rows = fs.readdirSync(directory, { withFileTypes: true }).filter((entry) => entry.isFile() && entry.name.endsWith(extension))
    .map((entry) => ({ file: path.join(directory, entry.name), stat: fs.lstatSync(path.join(directory, entry.name)) }))
    .filter((row) => !row.stat.isSymbolicLink() && row.stat.mtimeMs >= afterMs)
    .sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs);
  assert(rows.length === 1, `P-14 expected exactly one fresh ${extension} export`);
  return fs.readFileSync(rows[0].file);
}
function event(kind, data, last) {
  const milliseconds = Math.max(Date.now(), last.value + 1); last.value = milliseconds;
  return { kind, at: new Date(milliseconds).toISOString(), data };
}
function cliEnvironment(options) {
  return { ...process.env, OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile };
}
function cliText(options, args) {
  return run(CLI, args, { env: cliEnvironment(options) });
}
function cliField(value, name) {
  return value.match(new RegExp(`(?:^|\\n)${name}=([^\\n ]+)`, 'u'))?.[1];
}
function healthResult(options) {
  return spawnSync(CLI, ['health'], { encoding: 'utf8', timeout: 5_000, env: cliEnvironment(options) });
}

export async function runP14NativeChatProbes(options, dependencies = {}) {
  const expected = INSTALLED_UI_ENVIRONMENTS[options.environmentId];
  assert((dependencies.platform ?? process.platform) === 'linux' && expected, 'P-14 native probes require a supported Linux environment');
  assert(expected.session === 'X11' && (process.env.XDG_SESSION_TYPE ?? '').toLowerCase() === 'x11',
    'P-14 native file chooser and window lifecycle proof is unavailable on Wayland; refusing an X11-equivalent claim');
  assert(process.env.DISPLAY && process.env.DBUS_SESSION_BUS_ADDRESS, 'P-14 native probes require DISPLAY and the desktop D-Bus session');
  for (const tool of ['python3', 'xdotool']) commandExists(tool);
  assert(installedDesktopPIDs().length === 0, 'P-14 refuses to capture while a pre-existing installed desktop process is running');
  const downloadDir = safeDirectory(options.downloadDir, 'P-14 download directory');
  const supportDir = safeDirectory(options.supportDir, 'P-14 support directory');
  const launchApp = dependencies.launchApp ?? startApp;
  const appEnvironment = { ...cliEnvironment(options), OPENBURNBAR_DAEMON_SUPPORT_DIR: supportDir };
  let app = launchApp(options.outputDir, appEnvironment);
  const clock = { value: 0 };
  let daemonStopped = false;
  try {
    const primary = await waitFor('OpenBurnBar window', () => {
      const ids = windowIDs(app.pid); assert(ids.length === 1, 'expected one OpenBurnBar primary window'); return ids[0];
    });
    activate(options.outputDir, 'palette', 'Open command palette');
    activate(options.outputDir, 'route', 'Chat / Hermes');
    const initial = await waitFor('live chat semantics', () => {
      const tree = snapshot(options.outputDir, 'initial');
      assert(contains(tree, /live daemon chat history/iu) && contains(tree, /chat model/iu)
        && contains(tree, /thinking level/iu) && contains(tree, /attach files/iu), 'live chat semantics are incomplete');
      return tree;
    });
    activate(options.outputDir, 'backend', options.backendID);
    select(options.outputDir, 'model', 'Chat model', options.model);
    select(options.outputDir, 'thinking', 'Thinking level', options.thinking);

    activate(options.outputDir, 'attach', 'Attach files');
    const chooser = await waitFor('native file chooser', () => {
      const ids = run('xdotool', ['search', '--onlyvisible', '--name', 'Open|Select File|Choose']).split(/\s+/u).filter(Boolean);
      assert(ids.length >= 1, 'native chooser window is absent'); return ids.at(-1);
    });
    run('xdotool', ['windowactivate', '--sync', chooser]);
    run('xdotool', ['key', '--clearmodifiers', 'ctrl+l']);
    run('xdotool', ['type', '--clearmodifiers', '--delay', '1', options.attachmentPath]);
    run('xdotool', ['key', '--clearmodifiers', 'Return']);
    await sleep(300);
    run('xdotool', ['key', '--clearmodifiers', 'Return']);
    await waitFor('staged attachment', () => {
      const tree = snapshot(options.outputDir, 'attachment-staged');
      assert(contains(tree, new RegExp(path.basename(options.attachmentPath).replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u')),
        'attachment metadata did not reach the installed UI'); return tree;
    });
    setText(options.outputDir, 'composer', 'Message composer', `${options.searchMarker} UI attachment turn`);
    activate(options.outputDir, 'send', 'Send message');
    const complete = await waitFor('gateway response', () => {
      const tree = snapshot(options.outputDir, 'response');
      assert(contains(tree, /Response complete/iu) || contains(tree, /via Hermes/iu), 'gateway response is not complete'); return tree;
    }, 60_000);
    assert(selected(complete, options.model) || contains(complete, new RegExp(options.model.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u')),
      'selected model is not exposed by AT-SPI');
    assert(selected(complete, options.thinking) || contains(complete, new RegExp(options.thinking.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'iu')),
      'selected thinking level is not exposed by AT-SPI');

    activate(options.outputDir, 'older', 'Load earlier messages');
    const citationTree = await waitFor('memory citation', () => {
      const tree = snapshot(options.outputDir, 'citation'); assert(contains(tree, /Memory citations/iu), 'memory citation is absent'); return tree;
    });
    const citation = citationTree.nodes.find((node) => /^Open /u.test(node.name) && node.actions.length)?.name;
    assert(citation, 'no actionable memory citation was exposed');
    activate(options.outputDir, 'citation-open', citation);
    const citationOpened = await waitFor('citation target status', () => {
      const tree = snapshot(options.outputDir, 'citation-opened');
      assert(contains(tree, /^Cited source message opened\.$/u), 'citation target did not report a successful open');
      return tree;
    });
    const citationObservation = { activatedCitationID: options.citation.id, citedMessageID: options.citation.messageID,
      citedThreadID: options.citation.threadID, loadedPageMessageIDs: options.olderPageMessageIDs,
      selectedThreadIDAfter: options.threadID,
      status: names(citationOpened).find((name) => name === 'Cited source message opened.') };

    for (const decision of ['Approve', 'Reject', 'Cancel']) activate(options.outputDir, `approval-${decision.toLowerCase()}`, decision);
    const approvals = await waitFor('approval terminal states', () => {
      const tree = snapshot(options.outputDir, 'approvals');
      for (const state of ['approved', 'rejected', 'cancelled']) assert(contains(tree, new RegExp(state, 'iu')), `${state} approval is absent`);
      return tree;
    });
    const approvalNames = names(approvals);
    const approvalResponses = options.approvalRecords.map((record) => {
      const detail = cliText(options, ['run', 'get', record.runID]);
      const phase = cliField(detail, 'phase');
      assert(!cliField(detail, 'approval_id') && !cliField(detail, 'active_approval_id'),
        `P-14 ${record.decision} approval remained pending after the UI response`);
      assert(record.decision === 'approve' ? phase === 'completed' : phase === 'cancelled',
        `P-14 ${record.decision} approval reached unexpected daemon phase ${phase ?? 'missing'}`);
      const expectedStatus = record.decision === 'approve' ? 'approved' : record.decision === 'reject' ? 'rejected' : 'cancelled';
      const uiStatus = approvalNames.find((name) => name.toLowerCase().includes(expectedStatus))?.match(/approved|rejected|cancelled/iu)?.[0]?.toLowerCase();
      assert(uiStatus === expectedStatus, `P-14 ${record.decision} terminal status was not observed in the installed UI`);
      return { approvalID: record.approvalID, daemonApprovalID: record.approvalID, invokedDecision: record.decision,
        postResponsePhase: phase, uiStatus };
    });

    const exportStart = Date.now();
    activate(options.outputDir, 'export-json', 'Export chat as JSON');
    const exportJson = await waitFor('JSON export', () => newestFile(downloadDir, '.json', exportStart));
    select(options.outputDir, 'export-format', 'Chat export format', 'Markdown');
    activate(options.outputDir, 'export-markdown', 'Export chat as Markdown');
    const exportMarkdown = await waitFor('Markdown export', () => newestFile(downloadDir, '.md', exportStart));
    const beforeReconnect = JSON.parse(cliText(options, ['chat', 'thread', options.threadID, '--max-messages', '10000']));
    const beforeReconnectMessageIDs = beforeReconnect.messages.map((message) => message.id);

    run('systemctl', ['--user', 'stop', 'openburnbar-daemon.service']);
    daemonStopped = true;
    const disconnectedHealthResult = await waitFor('daemon disconnect', () => {
      const health = healthResult(options); assert(health.status !== 0, 'daemon health still succeeds'); return health;
    });
    const disconnected = await waitFor('chat disconnect status', () => {
      const tree = snapshot(options.outputDir, 'daemon-disconnected');
      assert(contains(tree, /offline|unavailable|disconnected/iu), 'installed chat did not expose daemon disconnect'); return tree;
    });
    run('systemctl', ['--user', 'start', 'openburnbar-daemon.service']);
    daemonStopped = false;
    const reconnectedHealthResult = await waitFor('daemon reconnect', () => {
      const health = healthResult(options);
      assert(health.status === 0 && /ok=true/iu.test(health.stdout), 'daemon health is not restored');
      return health;
    }, 30_000);
    activate(options.outputDir, 'options-reconnect', 'Chat options');
    activate(options.outputDir, 'reconnect', 'Reconnect gateway');
    const reconnected = await waitFor('chat reconnect status', () => {
      const tree = snapshot(options.outputDir, 'daemon-reconnected');
      assert(contains(tree, /live daemon chat history|connected|resumed/iu), 'installed chat did not expose daemon recovery'); return tree;
    });
    const afterReconnect = JSON.parse(cliText(options, ['chat', 'thread', options.threadID, '--max-messages', '10000']));
    const reconnectObservation = {
      beforeMessageIDs: beforeReconnectMessageIDs,
      afterMessageIDs: afterReconnect.messages.map((message) => message.id),
      disconnectedHealth: disconnectedHealthResult.status === 0,
      disconnectedStatus: names(disconnected).find((name) => /offline|unavailable|disconnected/iu.test(name)),
      reconnectedHealth: reconnectedHealthResult.status === 0 && /ok=true/iu.test(reconnectedHealthResult.stdout),
      reconnectedStatus: names(reconnected).find((name) => /live daemon chat history|connected|resumed/iu.test(name)),
      threadID: options.threadID
    };
    activate(options.outputDir, 'options', 'Chat options');
    activate(options.outputDir, 'popout', 'Pop out chat');
    const popouts = await waitFor('chat pop-out', () => {
      const ids = windowIDs(app.pid); assert(ids.length === 2, 'expected exactly one chat pop-out'); return ids;
    });
    const popout = popouts.find((id) => id !== primary);
    const firstFocusedWindowID = run('xdotool', ['getwindowfocus']);
    assert(firstFocusedWindowID === popout, 'first chat pop-out did not receive focus');
    activate(options.outputDir, 'options-existing', 'Chat options');
    activate(options.outputDir, 'popout-existing', 'Pop out chat');
    const secondWindowIDs = windowIDs(app.pid);
    const secondFocusedWindowID = run('xdotool', ['getwindowfocus']);
    assert(secondWindowIDs.length === 2 && secondFocusedWindowID === popout,
      'opening chat again did not focus the existing pop-out');
    run('xdotool', ['windowclose', popout]);
    const afterCloseWindowIDs = await waitFor('pop-out close', () => { const ids = windowIDs(app.pid); assert(ids.length === 1 && ids[0] === primary, 'primary window did not survive pop-out close'); return ids; });

    const exportedDocument = JSON.parse(exportJson);
    const exportedMessageIDs = exportedDocument.messages.map((message) => message.id);
    const exportedAttachment = exportedDocument.messages.flatMap((message) => message.attachments ?? [])
      .find((item) => item.sha256 === options.attachmentSha256);
    assert(exportedAttachment, 'P-14 export contains no matching durable attachment metadata');

    app.kill('SIGTERM');
    await waitForExit(app.pid);
    const firstAppPID = app.pid;
    app = launchApp(options.outputDir, appEnvironment);
    assert(app.pid !== firstAppPID, 'P-14 installed desktop relaunch reused the terminated process');
    await waitFor('relaunched OpenBurnBar window', () => {
      const ids = windowIDs(app.pid); assert(ids.length === 1, 'expected one relaunched OpenBurnBar primary window'); return ids[0];
    });
    activate(options.outputDir, 'relaunch-palette', 'Open command palette');
    activate(options.outputDir, 'relaunch-route', 'Chat / Hermes');
    await waitFor('reloaded attachment metadata', () => {
      const tree = snapshot(options.outputDir, 'attachment-reloaded');
      assert(contains(tree, new RegExp(exportedAttachment.fileName.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&'), 'u')),
        'durable attachment metadata did not return after desktop relaunch');
      return tree;
    });
    const postRelaunch = JSON.parse(cliText(options, ['chat', 'thread', options.threadID, '--max-messages', '500']));
    const durableAttachment = postRelaunch.messages.flatMap((message) => message.attachments ?? [])
      .find((item) => item.attachmentId === exportedAttachment.attachmentId);
    assert(durableAttachment, 'installed CLI lost durable attachment metadata after desktop relaunch');
    const registryFile = path.join(supportDir, 'chat-attachments', `${exportedAttachment.attachmentId}.bin`);
    const registryFilePresentAfterRelaunch = fs.existsSync(registryFile);

    const upstream = options.upstreamObservation;
    assert(upstream && upstream.model === options.effectiveModel && upstream.thinking === options.thinking,
      'P-14 controlled upstream did not observe the selected model and thinking level');
    assert(citationObservation && citationObservation.status === 'Cited source message opened.',
      'P-14 citation target identity/readback observation is unavailable');
    assert(Array.isArray(approvalResponses) && approvalResponses.length === 3,
      'P-14 daemon approval RPC readback is unavailable');
    assert(reconnectObservation.disconnectedHealth === false && reconnectObservation.reconnectedHealth === true,
      'P-14 real daemon disconnect/reconnect observation is unavailable');
    assert(registryFilePresentAfterRelaunch === false,
      'P-14 process-local attachment bytes remained available after desktop relaunch');

    const desktopTranscript = {
      producer: 'openburnbar-p14-installed-desktop-probe-v1',
      events: [
        event('model-thinking', { selectedModel: options.effectiveModel, upstreamModel: upstream.model,
          selectedThinking: options.thinking, upstreamThinking: upstream.thinking, fixtureMode: false }, clock),
        event('attachment', { chooserWindowID: chooser,
          input: { byteSize: options.attachmentByteSize, fileName: options.attachmentFileName,
            mimeType: options.attachmentMimeType, sha256: options.attachmentSha256 },
          exportMetadata: exportedAttachment, postRestartMetadata: durableAttachment,
          upstreamAttachment: upstream.attachment }, clock),
        event('citation', citationObservation, clock),
        event('approvals', { responses: approvalResponses }, clock),
        event('reconnect-visibility', reconnectObservation, clock),
        event('export', { daemonMessageIDs: beforeReconnectMessageIDs,
          exportedMessageIDs, threadID: options.threadID }, clock),
        event('popout', { primaryWindowID: primary,
          first: { focusedWindowID: firstFocusedWindowID, threadID: options.threadID, windowIDs: popouts },
          second: { focusedWindowID: secondFocusedWindowID, threadID: options.threadID, windowIDs: secondWindowIDs },
          afterCloseWindowIDs }, clock),
        event('attachment-restart-limit', { attachmentID: exportedAttachment.attachmentId,
          postRelaunchMetadataAttachmentID: durableAttachment.attachmentId,
          registryFilePresentAfterRelaunch }, clock)
      ]
    };
    return { desktopTranscript, exportJson, exportMarkdown,
      windowEvents: { producer: 'openburnbar-p14-installed-window-probe-v1',
        singlePopout: popouts.length === 2 && secondWindowIDs.length === 2,
        mainWindowSurvived: afterCloseWindowIDs.length === 1 && afterCloseWindowIDs[0] === primary,
        primaryWindowID: primary, popoutWindowID: popout } };
  } finally {
    if (daemonStopped) {
      try { run('systemctl', ['--user', 'start', 'openburnbar-daemon.service']); } catch { /* preserve primary failure */ }
    }
    try { app.kill('SIGTERM'); } catch { /* already stopped */ }
    await waitForExit(app.pid);
  }
}
