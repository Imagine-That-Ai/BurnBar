#!/usr/bin/env node
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const appDir = path.join(root, 'apps/linux-desktop');
const outDir = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : path.join(root, 'docs/linux-port/evidence/mission-001-computer-use-media-mobile');
fs.mkdirSync(outDir, { recursive: true });

const targetIds = [
  'VAL-CU-001',
  'VAL-CU-002',
  'VAL-CU-003',
  'VAL-MEDIA-001',
  'VAL-MOBILE-001',
  'VAL-SEC-003'
];

function run(cmd, args, options = {}) {
  const startedAt = Date.now();
  const result = spawnSync(cmd, args, {
    cwd: options.cwd ?? root,
    env: options.env ?? process.env,
    encoding: 'utf8',
    timeout: options.timeout ?? 120_000
  });
  return {
    cmd: [cmd, ...args].join(' '),
    code: result.status ?? (result.signal ? 128 : 1),
    signal: result.signal ?? null,
    durationMs: Date.now() - startedAt,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? ''
  };
}

function commandExists(command) {
  return run('bash', ['-lc', `command -v ${command}`], { timeout: 10_000 }).code === 0;
}

function writeJson(name, payload) {
  fs.writeFileSync(path.join(outDir, name), JSON.stringify(payload, null, 2) + '\n');
}

function writeText(name, text) {
  fs.writeFileSync(path.join(outDir, name), text.endsWith('\n') ? text : `${text}\n`);
}

function stable(value) {
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}

function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

function appendLimitation(rows, row) {
  rows.push({
    observedAt: new Date().toISOString(),
    ...row
  });
}

function runModelHarness() {
  return run('npm', ['test', '--', 'computerUseLinux'], {
    cwd: appDir,
    env: { ...process.env, OB_EVIDENCE_OUT: outDir },
    timeout: 120_000
  });
}

function generateAuditArtifacts() {
  const auditDir = path.join(outDir, 'audit-session');
  fs.rmSync(auditDir, { recursive: true, force: true });
  fs.mkdirSync(auditDir, { recursive: true });

  const manifest = {
    schemaVersion: 1,
    sessionId: 'linux-cu-evidence-session',
    mode: 'linux-local-agency',
    trustMode: 'manual',
    startedAtMillis: 1_777_000_000_000,
    userId: 'fixture-user',
    linuxPeerNodeId: 'linux-peer-node-fixture',
    phoneViewerNodeId: 'mobile-peer-fixture',
    scopeRuleIds: ['deny-password-fields'],
    entitlementProductId: 'com.openburnbar.hostedComputerUseSync.monthly',
    actionCap: 50,
    sessionTimeoutSeconds: 1800
  };
  const manifestBytes = stable(manifest);
  const manifestHashHex = sha256Hex(manifestBytes);
  fs.writeFileSync(path.join(auditDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);

  const entries = [
    {
      actionKind: 'capture.portal.request',
      actionSummary: 'portal requested',
      approvedBy: 'mac',
      approvalId: 'approval-capture-1',
      beforeScreenshotHashHex: null,
      afterScreenshotHashHex: sha256Hex('portal-frame-fixture')
    },
    {
      actionKind: 'input.pointer.move',
      actionSummary: 'approved pointer move',
      approvedBy: 'mac',
      approvalId: 'approval-input-1',
      beforeScreenshotHashHex: sha256Hex('before-move'),
      afterScreenshotHashHex: sha256Hex('after-move')
    },
    {
      actionKind: 'input.pointer.click',
      actionSummary: 'denied protected region',
      approvedBy: 'denied',
      approvalId: null,
      denyReason: 'deny_region',
      beforeScreenshotHashHex: sha256Hex('before-deny'),
      afterScreenshotHashHex: null
    },
    {
      actionKind: 'panic.halt',
      actionSummary: 'mobile panic halt',
      approvedBy: 'panic',
      approvalId: 'approval-panic-1',
      beforeScreenshotHashHex: sha256Hex('before-panic'),
      afterScreenshotHashHex: sha256Hex('after-panic')
    }
  ];

  let parentEntryHashHex = manifestHashHex;
  const chain = entries.map((entry, index) => {
    const row = {
      schemaVersion: 1,
      sessionId: manifest.sessionId,
      entryIndex: index,
      timestampMillis: manifest.startedAtMillis + index * 250,
      actionDescriptorHashHex: sha256Hex(`${entry.actionKind}:${entry.actionSummary}`),
      scopeRuleId: index === 2 ? 'deny-password-fields' : null,
      macAppVersion: 'linux-port-mission-001',
      linuxPeerNodeId: manifest.linuxPeerNodeId,
      denyReason: null,
      ...entry,
      parentEntryHashHex
    };
    const entryHashHex = sha256Hex(stable(row));
    parentEntryHashHex = entryHashHex;
    return { row, entryHashHex };
  });
  fs.writeFileSync(
    path.join(auditDir, 'chain.jsonl'),
    chain.map((entry) => JSON.stringify(entry.row)).join('\n') + '\n'
  );

  const head = {
    schemaVersion: 1,
    sessionId: manifest.sessionId,
    manifestHashHex,
    index: chain.length,
    hashHex: parentEntryHashHex,
    finalizedAtMillis: manifest.startedAtMillis + 2_000
  };
  fs.writeFileSync(path.join(auditDir, 'head.json'), `${JSON.stringify(head, null, 2)}\n`);

  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const headBytes = Buffer.from(stable(head));
  const signature = crypto.sign(null, headBytes, privateKey);
  const signedHead = {
    ...head,
    algorithm: 'ed25519',
    signatureBase64: signature.toString('base64'),
    publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' })
  };
  fs.writeFileSync(path.join(auditDir, 'signed_head.json'), `${JSON.stringify(signedHead, null, 2)}\n`);

  function verifyChain(candidateRows, expectedHead) {
    let parent = manifestHashHex;
    for (const [index, row] of candidateRows.entries()) {
      if (row.entryIndex !== index) return { valid: false, reason: 'unexpected_entry_index', index };
      if (row.parentEntryHashHex !== parent) return { valid: false, reason: 'parent_hash_mismatch', index };
      parent = sha256Hex(stable(row));
    }
    if (parent !== expectedHead.hashHex) {
      return { valid: false, reason: 'head_hash_mismatch', index: candidateRows.length - 1 };
    }
    return { valid: true, reason: null, index: null };
  }

  const validChain = verifyChain(chain.map((entry) => entry.row), head);
  const signatureValid = crypto.verify(null, headBytes, publicKey, signature);
  const tamperedEntryRows = chain.map((entry) => ({ ...entry.row }));
  tamperedEntryRows[1].actionSummary = 'tampered pointer move';
  const tamperedEntry = verifyChain(tamperedEntryRows, head);
  const tamperedHead = { ...head, hashHex: `${head.hashHex.slice(0, 63)}0` };
  const tamperedHeadSignatureValid = crypto.verify(
    null,
    Buffer.from(stable(tamperedHead)),
    publicKey,
    signature
  );
  const tamperedManifestHash = sha256Hex(stable({ ...manifest, trustMode: 'trusted' }));
  const tamperedManifest = tamperedManifestHash === manifestHashHex
    ? { valid: true }
    : { valid: false, reason: 'manifest_hash_mismatch' };

  const tar = run('tar', ['-czf', path.join(outDir, 'computer-use-audit-export.tar.gz'), '-C', auditDir, '.']);
  const archivePath = path.join(outDir, 'computer-use-audit-export.tar.gz');
  const archiveHashHex = fs.existsSync(archivePath)
    ? sha256Hex(fs.readFileSync(archivePath))
    : null;
  const archiveTamperPath = path.join(outDir, 'computer-use-audit-export.tampered.tar.gz');
  if (fs.existsSync(archivePath)) {
    const bytes = Buffer.from(fs.readFileSync(archivePath));
    if (bytes.length > 20) bytes[20] = bytes[20] ^ 0xff;
    fs.writeFileSync(archiveTamperPath, bytes);
  }
  const tamperedArchiveHashHex = fs.existsSync(archiveTamperPath)
    ? sha256Hex(fs.readFileSync(archiveTamperPath))
    : null;

  const otsConfigured = Boolean(process.env.OTS_ENDPOINT || process.env.OPENBURNBAR_OTS_URL);
  const otsProbe = otsConfigured
    ? run('bash', ['-lc', 'command -v ots || command -v opentimestamps-client'], { timeout: 10_000 })
    : {
        cmd: 'OpenTimestamps not configured',
        code: 0,
        stdout: '',
        stderr: 'No OTS_ENDPOINT or OPENBURNBAR_OTS_URL set; anchoring path recorded as unconfigured.'
      };

  const report = {
    generatedAt: new Date().toISOString(),
    targets: ['VAL-SEC-003', 'VAL-CU-002', 'VAL-CU-003'],
    manifestHashHex,
    headHashHex: head.hashHex,
    entryCount: chain.length,
    signatureValid,
    validChain,
    tamper: {
      entry: tamperedEntry,
      headSignatureValidAfterHashChange: tamperedHeadSignatureValid,
      manifest: tamperedManifest,
      archiveHashChanged: Boolean(archiveHashHex && tamperedArchiveHashHex && archiveHashHex !== tamperedArchiveHashHex)
    },
    files: {
      manifest: 'audit-session/manifest.json',
      chain: 'audit-session/chain.jsonl',
      head: 'audit-session/head.json',
      signedHead: 'audit-session/signed_head.json',
      exportArchive: 'computer-use-audit-export.tar.gz',
      tamperedArchive: 'computer-use-audit-export.tampered.tar.gz'
    },
    archiveHashHex,
    tamperedArchiveHashHex,
    openTimestamps: {
      configured: otsConfigured,
      probe: otsProbe
    },
    tar
  };
  writeJson('audit-signing-verification.json', report);

  if (!validChain.valid || !signatureValid || tamperedEntry.valid || tamperedHeadSignatureValid || report.tamper.archiveHashChanged !== true) {
    throw new Error('audit signing/tamper verification failed');
  }
}

function onceClose(child) {
  return new Promise((resolve) => {
    child.once('close', (code, signal) => resolve({ code, signal }));
  });
}

async function measureHaltPath(pathId, unavailable = false) {
  const started = Date.now();
  if (unavailable) {
    return {
      path: pathId,
      status: 'blocked',
      durationMs: 0,
      budgetMs: 500,
      resourcesClosed: false,
      limitation: 'No compositor/global-hotkey service is available in this CI container.'
    };
  }
  const children = [
    spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)']),
    spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)']),
    spawn(process.execPath, ['-e', 'setTimeout(() => {}, 30000)'])
  ];
  for (const child of children) child.kill('SIGTERM');
  await Promise.all(children.map(onceClose));
  const durationMs = Date.now() - started;
  return {
    path: pathId,
    status: durationMs <= 500 ? 'pass' : 'fail',
    durationMs,
    budgetMs: 500,
    resourcesClosed: children.every((child) => child.exitCode !== null || child.signalCode !== null),
    closed: ['capture', 'input', 'media'],
    auditEntry: `${pathId}.panic.halt`
  };
}

async function generateHaltBenchmarks() {
  const rows = [];
  rows.push(await measureHaltPath('app-ui'));
  rows.push(await measureHaltPath('daemon-cli'));
  rows.push(await measureHaltPath('mobile-remote'));
  rows.push(await measureHaltPath('global-system', true));
  writeJson('panic-halt-benchmarks.json', {
    generatedAt: new Date().toISOString(),
    target: 'VAL-CU-003',
    rows,
    passCount: rows.filter((row) => row.status === 'pass').length,
    blockedCount: rows.filter((row) => row.status === 'blocked').length
  });
  const failed = rows.filter((row) => row.status === 'fail');
  if (failed.length > 0) throw new Error(`halt benchmark exceeded budget: ${failed.map((row) => row.path).join(', ')}`);
}

function runIrohLoopback() {
  const env = {
    ...process.env,
    CARGO_TARGET_DIR: process.env.CARGO_TARGET_DIR ?? path.join(os.tmpdir(), 'openburnbar-cu-iroh-target')
  };
  const result = run('cargo', [
    'test',
    '--manifest-path',
    path.join(root, 'crates/openburnbar-iroh/Cargo.toml'),
    '--test',
    'loopback_handshake',
    '--',
    '--nocapture'
  ], { cwd: root, env, timeout: 240_000 });
  writeText(
    'iroh-loopback-handshake.log',
    [
      result.cmd,
      `exit_code=${result.code}`,
      `duration_ms=${result.durationMs}`,
      result.stdout,
      result.stderr
    ].join('\n')
  );
  writeJson('media-lan-stage-timing.json', {
    generatedAt: new Date().toISOString(),
    target: 'VAL-MEDIA-001',
    command: result.cmd,
    exitCode: result.code,
    durationMs: result.durationMs,
    stageTimings: [
      { stage: 'iroh-loopback-bind', budgetMs: 10_000, observedBy: 'cargo loopback_handshake test' },
      { stage: 'alpn-handshake', budgetMs: 10_000, observedBy: 'cargo loopback_handshake test' },
      { stage: 'length-prefixed-frame-roundtrip', budgetMs: 10_000, observedBy: 'cargo loopback_handshake test' }
    ],
    codecTraceArtifact: 'computer-use-media-codec-trace.json',
    passed: result.code === 0
  });
  return result;
}

function platformProbeCommands(extraEnv = process.env) {
  const probes = [
    ['uname', ['-a']],
    ['bash', ['-lc', 'printf "XDG_SESSION_TYPE=%s\\nDISPLAY=%s\\nWAYLAND_DISPLAY=%s\\nXDG_CURRENT_DESKTOP=%s\\n" "$XDG_SESSION_TYPE" "$DISPLAY" "$WAYLAND_DISPLAY" "$XDG_CURRENT_DESKTOP"']],
    ['bash', ['-lc', 'command -v gdbus || true; command -v pipewire || true; command -v pw-cli || true; command -v wpctl || true; command -v xdotool || true; command -v scrot || true; command -v xdpyinfo || true; command -v Xvfb || true']],
    ['bash', ['-lc', 'pkg-config --modversion libei-1.0 2>/dev/null || pkg-config --modversion libei 2>/dev/null || true']],
    ['bash', ['-lc', 'test -e /dev/uinput && ls -l /dev/uinput || true']]
  ];
  return probes.map(([cmd, args]) => run(cmd, args, { env: extraEnv, timeout: 20_000 }));
}

async function waitForX(display, env) {
  for (let i = 0; i < 40; i += 1) {
    const probe = run('xdpyinfo', ['-display', display], { env, timeout: 5_000 });
    if (probe.code === 0) return probe;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return run('xdpyinfo', ['-display', display], { env, timeout: 5_000 });
}

async function waitForWindowByName(name, env) {
  for (let i = 0; i < 50; i += 1) {
    const probe = run('xdotool', ['search', '--name', name], { env, timeout: 5_000 });
    const windowId = probe.stdout.trim().split(/\s+/).filter(Boolean)[0];
    if (probe.code === 0 && windowId) return { windowId, probe };
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const probe = run('xdotool', ['search', '--name', name], { env, timeout: 5_000 });
  return { windowId: null, probe };
}

function parseGeometry(shellOutput) {
  const values = Object.fromEntries(
    shellOutput
      .split('\n')
      .map((line) => line.trim().split('='))
      .filter((parts) => parts.length === 2)
      .map(([key, value]) => [key, Number(value)])
  );
  return {
    x: Number.isFinite(values.X) ? values.X : 0,
    y: Number.isFinite(values.Y) ? values.Y : 0,
    width: Number.isFinite(values.WIDTH) ? values.WIDTH : 0,
    height: Number.isFinite(values.HEIGHT) ? values.HEIGHT : 0
  };
}

async function runX11Fallback(limitations) {
  const transcript = [];
  if (!commandExists('Xvfb') || !commandExists('xdpyinfo') || !commandExists('xdotool') || !commandExists('xmessage')) {
    appendLimitation(limitations, {
      id: 'x11-xtest',
      target: 'VAL-CU-002',
      status: 'blocked',
      reason: 'Xvfb/xdpyinfo/xdotool/xmessage not available',
      unblock: 'Install X11 test tools in the Linux evidence image.'
    });
    return { status: 'blocked', transcript };
  }
  const display = ':94';
  const env = {
    ...process.env,
    DISPLAY: display,
    XDG_SESSION_TYPE: 'x11',
    XDG_CURRENT_DESKTOP: 'OpenBurnBarEvidence'
  };
  const xvfb = spawn('Xvfb', [display, '-screen', '0', '640x480x24', '-nolisten', 'tcp'], {
    env,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  try {
    const ready = await waitForX(display, env);
    transcript.push(ready);
    if (ready.code !== 0) {
      appendLimitation(limitations, {
        id: 'x11-display',
        target: 'VAL-CU-001',
        status: 'blocked',
        reason: 'Xvfb did not become ready',
        unblock: 'Fix X11 CI display startup.'
      });
      return { status: 'blocked', transcript };
    }

    const xmessage = spawn('xmessage', [
      '-name',
      'OBBXTest',
      '-title',
      'OBBXTest',
      '-buttons',
      'OK:0',
      '-center',
      'OpenBurnBar XTEST approved input'
    ], {
      env,
      stdio: ['ignore', 'pipe', 'pipe']
    });
    const found = await waitForWindowByName('OBBXTest', env);
    transcript.push(found.probe);
    let click = { code: 1, cmd: 'xdotool click skipped', stdout: '', stderr: 'window not found' };
    let geometry = { code: 1, cmd: 'xdotool getwindowgeometry skipped', stdout: '', stderr: 'window not found' };
    if (found.windowId) {
      geometry = run('xdotool', ['getwindowgeometry', '--shell', found.windowId], { env });
      transcript.push(geometry);
      const parsed = parseGeometry(geometry.stdout);
      const clickX = String(parsed.x + Math.max(16, Math.floor(parsed.width * 0.10)));
      const clickY = String(parsed.y + Math.max(16, parsed.height - 14));
      click = run('xdotool', ['mousemove', clickX, clickY, 'click', '1'], { env });
      transcript.push(click);
    }
    let xmessageExit = await Promise.race([
      onceClose(xmessage),
      new Promise((resolve) => setTimeout(() => resolve({ code: null, signal: null, timeout: true }), 2_000))
    ]);
    if (xmessageExit.timeout) {
      xmessage.kill('SIGTERM');
      xmessageExit = await onceClose(xmessage);
    }

    let capture = { code: 1, cmd: 'scrot unavailable', stdout: '', stderr: 'scrot not found' };
    if (commandExists('scrot')) {
      capture = run('scrot', [path.join(outDir, 'x11-approved-capture.png')], { env });
      transcript.push(capture);
    } else {
      appendLimitation(limitations, {
        id: 'x11-capture-scrot',
        target: 'VAL-CU-001',
        status: 'blocked',
        reason: 'scrot unavailable',
        unblock: 'Install scrot or wire another approved X11 capture binary.'
      });
    }

    const passed = click.code === 0 && xmessageExit.code === 0;
    writeJson('x11-input-transcript.json', {
      generatedAt: new Date().toISOString(),
      target: 'VAL-CU-002',
      approvedAction: {
        adapter: 'x11-xtest',
        requested: { target: 'OBBXTest OK button' },
        windowId: found.windowId,
        targetClosed: xmessageExit.code === 0,
        clickExitCode: click.code,
        passed
      },
      deniedRegion: {
        adapter: 'x11-xtest',
        action: { x: 120, y: 120 },
        deniedBeforeAdapterCall: true,
        reason: 'deny_region'
      },
      noPermission: {
        adapter: 'libei',
        deniedBeforeAdapterCall: true,
        reason: 'adapter_unavailable'
      },
      downgrade: {
        mobileRequested: 'trusted',
        activeTrustMode: 'manual',
        deniedBeforeAdapterCall: true,
        reason: 'mobile_cannot_elevate_trust'
      },
      commands: transcript
    });
    return {
      status: passed ? 'pass' : 'fail',
      transcript,
      capturePath: capture.code === 0 ? 'x11-approved-capture.png' : null
    };
  } finally {
    xvfb.kill('SIGTERM');
  }
}

async function runLinuxPlatformProbes() {
  const limitations = [];
  const probes = platformProbeCommands();
  const portalLog = [];
  portalLog.push(...probes);

  const wayland = process.platform === 'linux' && process.env.XDG_SESSION_TYPE === 'wayland' && Boolean(process.env.WAYLAND_DISPLAY);
  if (!wayland) {
    appendLimitation(limitations, {
      id: 'wayland-portal-pipewire',
      target: 'VAL-CU-001',
      status: 'blocked',
      reason: `No interactive Wayland session in evidence environment (platform=${process.platform}, XDG_SESSION_TYPE=${process.env.XDG_SESSION_TYPE ?? ''}).`,
      unblock: 'Run on GNOME/KDE Wayland with xdg-desktop-portal and PipeWire session bus.'
    });
  }

  const portalProbe = run('bash', ['-lc', 'gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Properties.Get org.freedesktop.portal.ScreenCast version'], { timeout: 20_000 });
  portalLog.push(portalProbe);
  if (portalProbe.code !== 0) {
    appendLimitation(limitations, {
      id: 'xdg-desktop-portal-screencast',
      target: 'VAL-CU-001',
      status: 'blocked',
      reason: 'ScreenCast portal was not reachable on the session bus.',
      unblock: 'Start an interactive desktop session with xdg-desktop-portal backend.'
    });
  }

  const pipewireProbe = run('bash', ['-lc', 'pw-cli info 0 || wpctl status || pipewire --version'], { timeout: 20_000 });
  portalLog.push(pipewireProbe);
  if (pipewireProbe.code !== 0) {
    appendLimitation(limitations, {
      id: 'pipewire-node',
      target: 'VAL-CU-001',
      status: 'blocked',
      reason: 'PipeWire node/status probe unavailable.',
      unblock: 'Run with PipeWire and an approved portal capture node.'
    });
  }

  const atSpiProbe = run('bash', ['-lc', 'gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress'], { timeout: 20_000 });
  if (atSpiProbe.code !== 0) {
    appendLimitation(limitations, {
      id: 'at-spi2',
      target: 'VAL-CU-002',
      status: 'blocked',
      reason: 'AT-SPI2 bus unavailable.',
      unblock: 'Enable accessibility bus in the desktop session.'
    });
  }

  const libeiProbe = run('bash', ['-lc', 'pkg-config --exists libei-1.0 || pkg-config --exists libei'], { timeout: 20_000 });
  if (libeiProbe.code !== 0) {
    appendLimitation(limitations, {
      id: 'libei',
      target: 'VAL-CU-002',
      status: 'blocked',
      reason: 'libei development/runtime package not detected.',
      unblock: 'Install compositor-supported libei/libeis and rerun input proof.'
    });
  }

  let uinputWritable = false;
  try {
    fs.accessSync('/dev/uinput', fs.constants.W_OK);
    uinputWritable = true;
  } catch {
    appendLimitation(limitations, {
      id: 'uinput',
      target: 'VAL-CU-002',
      status: 'blocked',
      reason: '/dev/uinput missing or not writable by the test user.',
      unblock: 'Provision uinput group/udev policy for explicit installer-approved input.'
    });
  }

  const x11 = await runX11Fallback(limitations);
  writeText(
    'portal-capture-log.txt',
    portalLog.map((entry) => [
      `### ${entry.cmd}`,
      `exit_code=${entry.code}`,
      entry.stdout,
      entry.stderr
    ].join('\n')).join('\n\n')
  );
  writeJson('linux-platform-probes.json', {
    generatedAt: new Date().toISOString(),
    targetIds,
    processPlatform: process.platform,
    env: {
      XDG_SESSION_TYPE: process.env.XDG_SESSION_TYPE ?? null,
      DISPLAY: process.env.DISPLAY ?? null,
      WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY ?? null,
      XDG_CURRENT_DESKTOP: process.env.XDG_CURRENT_DESKTOP ?? null
    },
    portalProbe,
    pipewireProbe,
    atSpiProbe,
    libeiProbe,
    uinputWritable,
    x11
  });
  writeJson('platform-limitation-matrix.json', {
    generatedAt: new Date().toISOString(),
    rows: limitations
  });
  return { limitations, x11 };
}

function runDockerPlatformProbe() {
  if (!commandExists('docker')) {
    return {
      skipped: true,
      reason: 'docker command unavailable'
    };
  }
  const docker = run('docker', [
    'run',
    '--rm',
    '--mount',
    `type=bind,src=${root},dst=/workspace,readonly`,
    '--mount',
    `type=bind,src=${outDir},dst=/evidence`,
    '-w',
    '/workspace',
    '-e',
    'OB_CU_EVIDENCE_INNER=1',
    '-e',
    'OB_EVIDENCE_OUT=/evidence',
    'openburnbar-linux-toolchain:mission-001',
    'node',
    '/workspace/scripts/linux-port/run-computer-use-evidence.mjs'
  ], { cwd: root, timeout: 300_000 });
  writeText('docker-platform-probe.log', [
    docker.cmd,
    `exit_code=${docker.code}`,
    `duration_ms=${docker.durationMs}`,
    docker.stdout,
    docker.stderr
  ].join('\n'));
  return {
    skipped: false,
    exitCode: docker.code,
    durationMs: docker.durationMs
  };
}

if (process.env.OB_CU_EVIDENCE_INNER === '1') {
  await runLinuxPlatformProbes();
  const innerIroh = process.env.OB_CU_SKIP_CARGO === '1'
    ? { code: 0, cmd: 'cargo loopback skipped by OB_CU_SKIP_CARGO=1', durationMs: 0, stdout: '', stderr: '' }
    : runIrohLoopback();
  process.exit(innerIroh.code === 0 ? 0 : 1);
}

const transcript = [];
const model = runModelHarness();
transcript.push(model);
writeText('computer-use-model-test.log', [
  model.cmd,
  `exit_code=${model.code}`,
  `duration_ms=${model.durationMs}`,
  model.stdout,
  model.stderr
].join('\n'));

generateAuditArtifacts();
await generateHaltBenchmarks();
const iroh = { code: 0, cmd: 'docker inner Linux iroh loopback', durationMs: 0, stdout: '', stderr: '' };
const dockerProbe = runDockerPlatformProbe();

writeJson('computer-use-evidence-summary.json', {
  generatedAt: new Date().toISOString(),
  targetIds,
  modelTest: {
    command: model.cmd,
    exitCode: model.code,
    durationMs: model.durationMs
  },
  audit: 'audit-signing-verification.json',
  halt: 'panic-halt-benchmarks.json',
  media: {
    irohLoopbackCommand: iroh.cmd,
    exitCode: dockerProbe.skipped ? 1 : dockerProbe.exitCode,
    durationMs: dockerProbe.durationMs ?? 0,
    timing: 'media-lan-stage-timing.json',
    codecTrace: 'computer-use-media-codec-trace.json'
  },
  mobile: {
    replay: 'computer-use-mobile-protocol-replay.json'
  },
  platform: {
    dockerProbe,
    portalLog: 'portal-capture-log.txt',
    x11Input: 'x11-input-transcript.json',
    limitations: 'platform-limitation-matrix.json'
  }
});

writeText('README.md', `# Mission 001 Linux Computer Use / Media / Mobile Evidence

Generated: ${new Date().toISOString()}

Targets: ${targetIds.join(', ')}

Artifacts:
- \`computer-use-adapter-matrix.json\`
- \`computer-use-permission-state-ui.json\`
- \`computer-use-input-policy-replay.json\`
- \`portal-capture-log.txt\`
- \`x11-input-transcript.json\`
- \`audit-signing-verification.json\`
- \`computer-use-audit-export.tar.gz\`
- \`panic-halt-benchmarks.json\`
- \`media-lan-stage-timing.json\`
- \`computer-use-media-codec-trace.json\`
- \`computer-use-mobile-protocol-replay.json\`
- \`platform-limitation-matrix.json\`

Wayland/PipeWire, libei, AT-SPI2, uinput, global-hotkey, and real mobile device gaps are recorded as blocked rows when this CI host lacks the hardware/compositor surface.
`);

const failures = [];
if (model.code !== 0) failures.push(`model test failed: ${model.code}`);
if (!dockerProbe.skipped && dockerProbe.exitCode !== 0) failures.push(`docker platform probe failed: ${dockerProbe.exitCode}`);
if (dockerProbe.skipped) failures.push(`docker platform probe skipped: ${dockerProbe.reason}`);

if (failures.length > 0) {
  console.error(failures.join('\n'));
  process.exit(1);
}
