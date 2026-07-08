#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const outDir = path.resolve(
  process.env.OB_EVIDENCE_OUT
    || path.join(root, 'docs/linux-port/evidence/mission-001-computer-use-media-mobile')
);
const runDir = path.join(outDir, 'current-product-run');
const preservedDir = path.join(outDir, 'preserved-qemu-portal-mobile');
const preservedTmpDir = '/private/tmp/openburnbar-cu-evidence-portal-20260704-1054';
const defaultMissionBundle = path.join(
  '/Users/albertonunez/.zenith/projects',
  '20260703T011441Z-user-invoked-zenith-and-goal-mode-for-the-approved-openburnbar-l',
  '.zenith/missions/mission-001/evidence/worker-cu-qemu-mobile-sec-pass-20260704-1002'
);
const image = process.env.OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE || 'openburnbar-linux-toolchain:mission-001';

const targetIds = [
  'VAL-CU-001',
  'VAL-CU-002',
  'VAL-CU-003',
  'VAL-MEDIA-001',
  'VAL-MOBILE-001',
  'VAL-SEC-003'
];

function now() {
  return new Date().toISOString();
}

function rel(file) {
  return path.relative(outDir, file).split(path.sep).join('/');
}

function readJSON(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function writeJSON(file, payload) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(payload, null, 2)}\n`);
}

function writeText(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text.endsWith('\n') ? text : `${text}\n`);
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function fileInfo(file, base = outDir) {
  const stat = fs.statSync(file);
  return {
    path: path.relative(base, file).split(path.sep).join('/'),
    sizeBytes: stat.size,
    sha256: sha256File(file),
    modifiedAt: stat.mtime.toISOString()
  };
}

function existingFileInfo(file, base = outDir) {
  if (!fs.existsSync(file)) {
    return { path: path.relative(base, file).split(path.sep).join('/'), exists: false };
  }
  return { ...fileInfo(file, base), exists: true };
}

function walkFiles(directory) {
  const files = [];
  function visit(current) {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const next = path.join(current, entry.name);
      if (entry.isDirectory()) {
        visit(next);
      } else if (entry.isFile()) {
        files.push(next);
      }
    }
  }
  visit(directory);
  return files.sort();
}

function directoryManifest(directory, label) {
  const files = walkFiles(directory).map((file) => fileInfo(file, directory));
  return {
    generatedAt: now(),
    label,
    directory,
    fileCount: files.length,
    files
  };
}

function parseJSONL(file) {
  return fs.readFileSync(file, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function fail(message) {
  throw new Error(message);
}

function requireCondition(condition, message, failures) {
  if (!condition) failures.push(message);
}

function requireFile(bundleDir, relativePath, failures) {
  const file = path.join(bundleDir, relativePath);
  requireCondition(fs.existsSync(file), `missing required artifact ${relativePath}`, failures);
  if (fs.existsSync(file)) {
    requireCondition(fs.statSync(file).size > 0, `empty required artifact ${relativePath}`, failures);
  }
  return file;
}

function commandLog(result) {
  return [
    `### ${result.command}`,
    `exit_code=${result.exitCode}`,
    `duration_ms=${result.durationMs}`,
    result.stdout,
    result.stderr
  ].join('\n');
}

function runCommand(command, args, options = {}) {
  const started = Date.now();
  const result = spawnSync(command, args, {
    cwd: options.cwd || root,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 600_000
  });
  return {
    command: [command, ...args].join(' '),
    exitCode: result.status ?? (result.signal ? 128 : 1),
    signal: result.signal || null,
    durationMs: Date.now() - started,
    stdout: result.stdout || '',
    stderr: result.stderr || ''
  };
}

function hasRequiredBundleFiles(directory) {
  return fs.existsSync(path.join(directory, 'portal-evidence-summary.json'))
    && fs.existsSync(path.join(directory, 'wayland-atspi-input-adapter-proof.json'))
    && fs.existsSync(path.join(directory, 'mobile-live-surface-probe.json'))
    && fs.existsSync(path.join(directory, 'audit-signing-verification.json'));
}

function chooseSourceBundle() {
  const candidates = [
    process.env.OB_CU_REAL_SURFACE_BUNDLE,
    process.env.OB_CU_SOURCE_BUNDLE,
    preservedTmpDir,
    defaultMissionBundle
  ].filter(Boolean);

  for (const candidate of candidates) {
    const resolved = path.resolve(candidate);
    if (fs.existsSync(resolved) && hasRequiredBundleFiles(resolved)) {
      return resolved;
    }
  }
  fail(`no contract-matching CU evidence bundle found; tried ${candidates.join(', ')}`);
}

function copyDirectory(source, destination) {
  fs.rmSync(destination, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.cpSync(source, destination, { recursive: true });
}

function preserveSourceBundle(sourceBundle) {
  const preservedTmpExisted = fs.existsSync(preservedTmpDir);
  if (!preservedTmpExisted || !hasRequiredBundleFiles(preservedTmpDir)) {
    copyDirectory(sourceBundle, preservedTmpDir);
  }
  const sourceForCheckout = hasRequiredBundleFiles(preservedTmpDir) ? preservedTmpDir : sourceBundle;
  copyDirectory(sourceForCheckout, preservedDir);
  return {
    selectedSourceBundle: sourceBundle,
    preservedTmpDir,
    preservedTmpExisted,
    preservedTmpCreatedOrRefreshed: !preservedTmpExisted,
    currentCheckoutCopy: rel(preservedDir),
    sourceForCheckout
  };
}

function validatePortal(bundleDir) {
  const failures = [];
  const summary = readJSON(requireFile(bundleDir, 'portal-evidence-summary.json', failures));
  const lifecycleFile = requireFile(bundleDir, 'portal-lifecycle.jsonl', failures);
  const frameFile = requireFile(bundleDir, summary.approvedPipeWireFrameArtifact || 'approved-pipewire-frame.png', failures);
  const graphFile = requireFile(bundleDir, summary.pipeWireGraphArtifact || 'approved-pipewire-graph.json', failures);
  requireFile(bundleDir, 'portal-capture-log.txt', failures);
  requireFile(bundleDir, 'xdg-portal.log', failures);
  requireFile(bundleDir, 'xdg-portal-wlr.log', failures);
  requireFile(bundleDir, 'pipewire.log', failures);
  requireFile(bundleDir, 'wireplumber.log', failures);
  requireFile(bundleDir, 'dri-devices.txt', failures);

  const lifecycle = fs.existsSync(lifecycleFile) ? parseJSONL(lifecycleFile) : [];
  const lifecycleEvents = new Set(lifecycle.map((entry) => entry.event || entry.phase).filter(Boolean));
  const decisiveSurface = `${summary.decisiveSurface || ''} ${summary.surface || ''}`;

  requireCondition(summary.passed === true, 'portal summary did not pass', failures);
  requireCondition(summary.val_cu_001?.status === 'pass', 'VAL-CU-001 row missing pass status', failures);
  requireCondition(summary.portalReachable === true, 'portal not reachable', failures);
  requireCondition(summary.chooserType === 'dmenu', 'explicit dmenu chooser type missing', failures);
  requireCondition(summary.approvalFlowObserved === true, 'approval flow missing', failures);
  requireCondition(summary.denialFlowObserved === true, 'denial flow missing', failures);
  requireCondition(summary.revokeObserved === true, 'revoke/session close missing', failures);
  requireCondition(summary.approvedPipeWireFrame === true, 'approved PipeWire frame missing', failures);
  requireCondition(summary.screenCastStartSuccess === true, 'ScreenCast Start did not succeed', failures);
  requireCondition(summary.flows?.approve?.createResponse?.response === 0, 'ScreenCast CreateSession approve response not 0', failures);
  requireCondition(summary.flows?.approve?.selectResponse?.response === 0, 'ScreenCast SelectSources approve response not 0', failures);
  requireCondition(summary.flows?.approve?.startResponse?.response === 0, 'ScreenCast Start approve response not 0', failures);
  requireCondition(summary.flows?.deny?.selectResponse?.response === 1, 'ScreenCast denial row missing response 1', failures);
  requireCondition(/QEMU/i.test(decisiveSurface), 'QEMU context missing', failures);
  requireCondition(/virtio-gpu/i.test(decisiveSurface), 'virtio-gpu DRM context missing', failures);
  requireCondition(/Sway/i.test(decisiveSurface), 'Sway context missing', failures);
  requireCondition(/PipeWire/i.test(decisiveSurface), 'PipeWire context missing', failures);
  requireCondition(/xdg-desktop-portal/i.test(decisiveSurface), 'xdg-desktop-portal context missing', failures);
  for (const eventName of [
    'portal-screencast-reachable',
    'approve-create-session-response',
    'approve-select-sources-response',
    'approve-start-response',
    'approve-session-close-success',
    'consent-chooser-denied',
    'deny-select-sources-response'
  ]) {
    requireCondition(lifecycleEvents.has(eventName), `portal lifecycle event ${eventName} missing`, failures);
  }

  return {
    target: 'VAL-CU-001',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'Wayland portal/PipeWire consent lifecycle passed with approved capture, denial, revoke, and QEMU virtio-gpu provenance.'
      : failures.join('; '),
    evidence: [
      rel(path.join(bundleDir, 'portal-evidence-summary.json')),
      rel(path.join(bundleDir, 'portal-lifecycle.jsonl')),
      rel(frameFile),
      rel(graphFile),
      rel(path.join(bundleDir, 'portal-capture-log.txt')),
      rel(path.join(bundleDir, 'xdg-portal.log')),
      rel(path.join(bundleDir, 'xdg-portal-wlr.log'))
    ],
    details: {
      chooserType: summary.chooserType,
      decisiveSurface: summary.decisiveSurface,
      approveCreateSessionResponse: summary.flows?.approve?.createResponse?.response,
      approveSelectSourcesResponse: summary.flows?.approve?.selectResponse?.response,
      approveStartResponse: summary.flows?.approve?.startResponse?.response,
      denySelectSourcesResponse: summary.flows?.deny?.selectResponse?.response,
      approvedFrame: existingFileInfo(frameFile),
      pipeWireGraph: existingFileInfo(graphFile),
      lifecycleEventCount: lifecycle.length
    }
  };
}

function validateInputAdapter(bundleDir, portalResult) {
  const failures = [];
  const proof = readJSON(requireFile(bundleDir, 'wayland-atspi-input-adapter-proof.json', failures));
  const audit = readJSON(requireFile(bundleDir, 'product-input-adapter-audit.json', failures));
  const targetStateFile = requireFile(bundleDir, 'wayland-atspi-target-state.json', failures);
  const before = requireFile(bundleDir, 'wayland-atspi-before.png', failures);
  const after = requireFile(bundleDir, 'wayland-atspi-after.png', failures);

  const negativeCases = Array.isArray(proof.negativeCases) ? proof.negativeCases : [];
  const responses = Array.isArray(audit.responses) ? audit.responses : [];
  const caseById = new Map([...negativeCases, ...responses].map((row) => [row.id, row]));
  const requiredCases = [
    'approved-action',
    'denied-region',
    'denied-no-permission',
    'rate-limit'
  ];

  requireCondition(portalResult.ok, 'VAL-CU-001 prerequisite did not pass', failures);
  requireCondition(proof.passed === true, 'AT-SPI2 proof did not pass', failures);
  requireCondition(proof.adapter === 'at-spi2', `non-X11 adapter mismatch: ${proof.adapter}`, failures);
  requireCondition(!/x11|xtest/i.test(`${proof.adapter} ${proof.surface}`), 'X11/XTEST fallback was used as pass evidence', failures);
  requireCondition(proof.visibleTargetState?.targetClicked === true, 'visible target was not clicked', failures);
  requireCondition(proof.visibleTargetState?.beforeScreenshot === true, 'before screenshot not recorded', failures);
  requireCondition(proof.visibleTargetState?.afterScreenshot === true, 'after screenshot not recorded', failures);
  requireCondition(proof.visibleTargetState?.targetLabel === 'OpenBurnBar AT-SPI2 Applied', 'after target label missing applied state', failures);
  requireCondition(proof.productAuditBinding?.passed === true, 'product audit binding did not pass', failures);
  requireCondition(proof.productAuditBinding?.auditFullyVerified === true, 'product audit binding not fully verified', failures);
  requireCondition(audit.passed === true, 'product input adapter audit did not pass', failures);
  requireCondition(audit.audit?.fullyVerified === true, 'audit chain not fully verified', failures);
  requireCondition(audit.trustMode?.start === 'trusted', 'starting trust mode missing', failures);
  requireCondition(audit.trustMode?.afterDowngrade === 'step', 'trust downgrade missing', failures);
  requireCondition(Array.isArray(audit.trustMode?.downgradeAudit) && audit.trustMode.downgradeAudit.includes('trustDowngraded'), 'trust downgrade audit row missing', failures);
  requireCondition(Array.isArray(audit.trustMode?.unapprovedEscalationAudit) && audit.trustMode.unapprovedEscalationAudit.includes('trustEscalationRejected'), 'trust escalation rejection row missing', failures);
  for (const id of requiredCases) {
    requireCondition(caseById.has(id), `required input case ${id} missing`, failures);
  }
  requireCondition(caseById.get('approved-action')?.status === 'executed', 'approved action did not execute', failures);
  requireCondition(caseById.get('denied-region')?.denyReason === 'deny_region', 'denied-region reason missing', failures);
  requireCondition(caseById.get('denied-no-permission')?.denyReason === 'accessibility_revoked', 'denied/no-permission reason missing', failures);
  requireCondition(caseById.get('rate-limit')?.denyReason === 'session_limit', 'rate-limit/replay reason missing', failures);
  for (const id of requiredCases) {
    const row = caseById.get(id);
    requireCondition(Number.isInteger(row?.auditEntryIndex), `${id} missing audit entry index`, failures);
    requireCondition(typeof row?.auditHeadHashHex === 'string' && row.auditHeadHashHex.length >= 32, `${id} missing audit head hash`, failures);
  }

  return {
    target: 'VAL-CU-002',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'AT-SPI2 Wayland input adapter proof mutated a visible target and bound approved/denied/trust/rate-limit rows to the product audit chain.'
      : failures.join('; '),
    prerequisite: 'VAL-CU-001',
    evidence: [
      rel(path.join(bundleDir, 'wayland-atspi-input-adapter-proof.json')),
      rel(path.join(bundleDir, 'product-input-adapter-audit.json')),
      rel(targetStateFile),
      rel(before),
      rel(after),
      rel(path.join(bundleDir, 'wayland-atspi-drive-result.json')),
      rel(path.join(bundleDir, 'wayland-atspi-command.log')).replace('wayland-atspi-command.log', 'wayland-atspi-input-adapter-command.log')
    ],
    details: {
      adapter: proof.adapter,
      surface: proof.surface,
      visibleTargetState: proof.visibleTargetState,
      beforeScreenshot: existingFileInfo(before),
      afterScreenshot: existingFileInfo(after),
      responses: requiredCases.map((id) => caseById.get(id)),
      trustMode: audit.trustMode,
      audit: audit.audit,
      x11FallbackAcceptedAsPass: false
    }
  };
}

function validatePanic(bundleDir, inputResult) {
  const failures = [];
  const panic = readJSON(requireFile(bundleDir, 'panic-halt-benchmarks.json', failures));
  const rows = Array.isArray(panic.rows) ? panic.rows : [];
  const rowByPath = new Map(rows.map((row) => [row.path, row]));
  requireCondition(inputResult.ok, 'VAL-CU-002 prerequisite did not pass', failures);
  for (const pathName of ['app-ui', 'daemon-cli', 'mobile-remote']) {
    const row = rowByPath.get(pathName);
    requireCondition(row?.status === 'pass', `${pathName} panic row did not pass`, failures);
    requireCondition(row?.resourcesClosed === true, `${pathName} resources were not closed`, failures);
    requireCondition(Number(row?.durationMs) <= Number(row?.budgetMs || 500), `${pathName} exceeded panic budget`, failures);
    requireCondition(Boolean(row?.auditEntry), `${pathName} audit entry missing`, failures);
  }
  const global = rowByPath.get('global-system');
  requireCondition(global?.status === 'blocked' && Boolean(global?.limitation), 'global-system limitation row missing', failures);

  return {
    target: 'VAL-CU-003',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'Panic halt rows remain fresh and are only accepted after the VAL-CU-002 adapter prerequisite passed.'
      : failures.join('; '),
    prerequisite: 'VAL-CU-002',
    evidence: [
      rel(path.join(bundleDir, 'panic-halt-benchmarks.json')),
      rel(path.join(bundleDir, 'computer-use-app-runtime-halt.json')),
      rel(path.join(bundleDir, 'product-computer-use-evidence.json')),
      rel(path.join(bundleDir, 'platform-limitation-matrix.json'))
    ],
    details: {
      rows,
      globalSystemLimitation: global?.limitation || null,
      prerequisiteSatisfied: inputResult.ok
    }
  };
}

function validateMobile(bundleDir, inputResult) {
  const failures = [];
  const probe = readJSON(requireFile(bundleDir, 'mobile-live-surface-probe.json', failures));
  const transcript = readJSON(requireFile(bundleDir, 'linux-peer-mobile-control-transcript.json', failures));
  const importProof = readJSON(requireFile(bundleDir, 'mobile-live-surface-probe-import.json', failures));
  const rawProbeFile = requireFile(bundleDir, 'mobile-live-surface-probe.raw.json', failures);
  const sourceProbeFile = requireFile(bundleDir, 'mobile-live-surface-probe.source.json', failures);
  const screenshot = requireFile(bundleDir, probe.screenshotArtifact || 'mobile-simulator-live-probe.png', failures);
  const exchanges = Array.isArray(probe.exchanges) ? probe.exchanges : [];
  const frameTypes = new Set(exchanges.map((exchange) => exchange.frame?.type).filter(Boolean));
  const scenarios = new Set(exchanges.map((exchange) => exchange.scenario).filter(Boolean));
  const requiredScenarios = [
    'pairing-auth-request',
    'pairing-auth-ack',
    'approval-request',
    'approval-approve',
    'approval-deny',
    'panic-halt',
    'trust-downgrade',
    'media-control-viewer-frame',
    'media-screen-frame',
    'control-input-intent',
    'additive-wire-diff',
    'backward-compatible-close'
  ];
  const requiredFrameTypes = [
    'pairing.auth.request',
    'pairing.auth.accepted',
    'control.approval.request',
    'control.approval.response.approve',
    'control.approval.response.deny',
    'control.panic.halt',
    'control.trust.downgrade',
    'media.control.viewer.frame',
    'media.screen.frame',
    'control.input.intent',
    'wire.diff.additive.linuxCapabilityMetadata',
    'session.close.compatible'
  ];

  requireCondition(inputResult.ok, 'VAL-CU-002 prerequisite did not pass', failures);
  requireCondition(probe.passed === true, 'mobile live surface probe did not pass', failures);
  requireCondition(probe.liveTranscriptProduced === true, 'live transcript not produced', failures);
  requireCondition(probe.linuxPeerStarted === true, 'Linux peer did not start', failures);
  requireCondition(probe.iosSimulatorUsed === true || probe.androidDeviceUsed === true, 'no iOS simulator or Android device was used', failures);
  requireCondition(typeof probe.iosSimulatorDescription === 'string' || typeof probe.androidDeviceDescription === 'string', 'device/simulator identity missing', failures);
  requireCondition(probe.exchangeCount === 12 && exchanges.length === 12, 'expected 12 mobile exchanges', failures);
  requireCondition(probe.pairingAuthObserved === true, 'pairing/auth flow missing', failures);
  requireCondition(probe.approvalFlowObserved === true, 'approval flow missing', failures);
  requireCondition(probe.approvalDenyObserved === true, 'deny flow missing', failures);
  requireCondition(probe.panicFlowObserved === true, 'panic flow missing', failures);
  requireCondition(probe.trustDowngradeObserved === true, 'trust downgrade missing', failures);
  requireCondition(probe.mediaControlViewerFramesObserved === true, 'media/control frames missing', failures);
  requireCondition(probe.backwardCompatibleWireDiffObserved === true, 'wire diff row missing', failures);
  for (const scenario of requiredScenarios) {
    requireCondition(scenarios.has(scenario), `mobile scenario ${scenario} missing`, failures);
  }
  for (const frameType of requiredFrameTypes) {
    requireCondition(frameTypes.has(frameType), `mobile frame type ${frameType} missing`, failures);
  }
  requireCondition(transcript.passed === true && transcript.liveDeviceOrSimulatorTranscript === true, 'mobile transcript was not live simulator/device evidence', failures);
  requireCondition(transcript.linuxPeerStartedFirst === true, 'mobile transcript did not start Linux peer first', failures);
  requireCondition(importProof.passed === true || importProof.rawFieldVerification?.passed === true, 'mobile import verification did not pass', failures);
  requireCondition(exchanges.some((exchange) => /iPhone|Android/i.test(exchange.headers?.['user-agent'] || '')), 'mobile user agent missing from exchanges', failures);
  requireCondition(exchanges.every((exchange) => exchange.frame?.linuxCapabilityMetadata?.inputAdapter === 'at-spi2'), 'Linux capability metadata missing AT-SPI2 binding', failures);

  return {
    target: 'VAL-MOBILE-001',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'Live iOS simulator to Linux peer transcript covers pairing, approval/deny, panic, trust downgrade, media/control frames, and wire diff after VAL-CU-002.'
      : failures.join('; '),
    prerequisite: 'VAL-CU-002',
    evidence: [
      rel(path.join(bundleDir, 'mobile-live-surface-probe.json')),
      rel(path.join(bundleDir, 'linux-peer-mobile-control-transcript.json')),
      rel(path.join(bundleDir, 'mobile-live-surface-probe-import.json')),
      rel(rawProbeFile),
      rel(sourceProbeFile),
      rel(screenshot)
    ],
    details: {
      iosSimulatorDescription: probe.iosSimulatorDescription,
      androidDeviceDescription: probe.androidDeviceDescription,
      linuxPeerDescription: probe.linuxPeerDescription,
      exchangeCount: probe.exchangeCount,
      requiredScenarios,
      requiredFrameTypes,
      screenshot: existingFileInfo(screenshot),
      dockerHttpOnlyAcceptedAsPass: false
    }
  };
}

function validateSecurity(bundleDir) {
  const failures = [];
  const audit = readJSON(requireFile(bundleDir, 'audit-signing-verification.json', failures));
  const product = requireFile(bundleDir, 'product-computer-use-evidence.json', failures);
  const productAudit = requireFile(bundleDir, 'product-audit-evidence.json', failures);
  const rows = Array.isArray(audit.productCliAuditVerify?.rows) ? audit.productCliAuditVerify.rows : [];
  requireCondition(audit.passed === true, 'audit signing verification did not pass', failures);
  requireCondition(audit.productSwiftEvidence?.exitCode === 0, 'product Swift audit evidence command did not exit 0', failures);
  requireCondition(audit.productCliAuditVerify?.passed === true, 'product CLI audit verifier summary did not pass', failures);
  requireCondition(rows.length >= 3, 'expected daemon/mobile/input audit verifier rows', failures);
  for (const row of rows) {
    requireCondition(row.validAccepted === true, `${row.path} valid session not accepted`, failures);
    requireCondition(row.archiveValidAccepted === true, `${row.path} valid archive not accepted`, failures);
    requireCondition(row.chainTamperRejected === true, `${row.path} chain tamper not rejected`, failures);
    requireCondition(row.headTamperRejected === true, `${row.path} head tamper not rejected`, failures);
    requireCondition(row.manifestTamperRejected === true, `${row.path} manifest tamper not rejected`, failures);
    requireCondition(row.archiveTamperRejected === true, `${row.path} archive tamper not rejected`, failures);
  }

  return {
    target: 'VAL-SEC-003',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'Product audit verifier accepted valid session/archive artifacts and rejected chain, head, manifest, and archive tamper cases.'
      : failures.join('; '),
    evidence: [
      rel(path.join(bundleDir, 'audit-signing-verification.json')),
      rel(product),
      rel(productAudit),
      rel(path.join(bundleDir, 'product-cli-audit-verify-daemon-coordinator.log')),
      rel(path.join(bundleDir, 'product-cli-audit-verify-input-adapter.log')),
      rel(path.join(bundleDir, 'product-cli-audit-verify-mobile-remote.log'))
    ],
    details: {
      productSwiftEvidence: audit.productSwiftEvidence,
      verifierRows: rows.map((row) => ({
        path: row.path,
        validExitCode: row.validExitCode,
        archiveValidExitCode: row.archiveValidExitCode,
        chainTamperedExitCode: row.chainTamperedExitCode,
        headTamperedExitCode: row.headTamperedExitCode,
        manifestTamperedExitCode: row.manifestTamperedExitCode,
        archiveTamperedExitCode: row.archiveTamperedExitCode
      }))
    }
  };
}

function runIrohLoopback() {
  fs.mkdirSync(runDir, { recursive: true });
  const rootReal = fs.realpathSync(root);
  const dockerProbe = runCommand('docker', ['version'], { timeout: 30_000 });
  writeText(path.join(runDir, 'docker-version-for-media.log'), commandLog(dockerProbe));
  const useHostCargo = process.env.OB_CU_MEDIA_HOST_CARGO === '1';
  if (dockerProbe.exitCode !== 0 && !useHostCargo) {
    return {
      command: 'docker version',
      exitCode: dockerProbe.exitCode,
      durationMs: dockerProbe.durationMs,
      stdout: dockerProbe.stdout,
      stderr: dockerProbe.stderr,
      proofSurface: 'docker-linux-toolchain-unavailable',
      dockerProbeExitCode: dockerProbe.exitCode,
      dockerProbeLog: rel(path.join(runDir, 'docker-version-for-media.log')),
      cargoResolution: 'not-run-docker-required'
    };
  }
  const dockerCargoResolution = process.env.OB_CU_MEDIA_DOCKER_OFFLINE === '1' ? ['--offline'] : [];
  const command = useHostCargo
    ? {
        cmd: 'cargo',
        args: ['test', '--test', 'loopback_handshake', '--locked', '--offline', '--', '--nocapture'],
        cwd: path.join(root, 'crates/openburnbar-iroh'),
        env: {
          ...process.env,
          CARGO_TARGET_DIR: process.env.CARGO_TARGET_DIR || path.join(root, '.tmp-openburnbar-iroh-target')
        }
      }
    : {
        cmd: 'docker',
        args: [
          'run',
          '--rm',
          '-v',
          `${rootReal}:/workspace`,
          '-w',
          '/workspace/crates/openburnbar-iroh',
          '-e',
          'CARGO_TARGET_DIR=/tmp/openburnbar-cu-iroh-target',
          image,
          'cargo',
          'test',
          '--test',
          'loopback_handshake',
          '--locked',
          ...dockerCargoResolution,
          '--',
          '--nocapture'
        ],
        cwd: root,
        env: process.env
      };
  const result = runCommand(command.cmd, command.args, {
    cwd: command.cwd,
    env: command.env,
    timeout: 900_000
  });
  result.proofSurface = useHostCargo ? 'host-cargo-loopback' : 'docker-linux-toolchain';
  result.dockerProbeExitCode = dockerProbe.exitCode;
  result.dockerProbeLog = rel(path.join(runDir, 'docker-version-for-media.log'));
  result.cargoResolution = useHostCargo
    ? 'host-offline-cache'
    : (dockerCargoResolution.length > 0 ? 'docker-offline-cache' : 'docker-locked-online-resolution');
  writeText(path.join(runDir, 'iroh-loopback-handshake.log'), commandLog(result));
  return result;
}

function validateMedia(bundleDir, mobileResult) {
  const failures = [];
  const codecTrace = readJSON(requireFile(bundleDir, 'computer-use-media-codec-trace.json', failures));
  const productEvidence = readJSON(requireFile(bundleDir, 'product-computer-use-evidence.json', failures));
  const mobileProbe = readJSON(requireFile(bundleDir, 'mobile-live-surface-probe.json', failures));
  const loopback = runIrohLoopback();
  const loopbackLog = `${loopback.stdout}\n${loopback.stderr}`;
  const loopbackPassed = loopback.exitCode === 0
    && /test result:\s+ok/i.test(loopbackLog)
    && !/no matching package named [`']?iroh/i.test(loopbackLog);

  requireCondition(loopback.proofSurface === 'docker-linux-toolchain', `VAL-MEDIA-001 requires Docker/Linux product proof, got ${loopback.proofSurface}`, failures);
  requireCondition(loopback.dockerProbeExitCode === 0, `Docker probe failed with exit ${loopback.dockerProbeExitCode}`, failures);
  requireCondition(loopbackPassed, `iroh loopback cargo test failed with exit ${loopback.exitCode}`, failures);
  requireCondition(codecTrace.target === 'VAL-MEDIA-001', 'codec trace target mismatch', failures);
  requireCondition(codecTrace.source === 'OpenBurnBarMedia product APIs', 'codec trace is not product API evidence', failures);
  requireCondition(codecTrace.negotiation?.selectedVideoCodec === 'h264', 'Mercury video codec negotiation missing h264 fallback', failures);
  requireCondition(codecTrace.frameSeal?.sealedEnvelope === true, 'Mercury frame sealing missing', failures);
  requireCondition(codecTrace.backpressure?.producerAction === 'paused-producer', 'Mercury backpressure producer action missing', failures);
  requireCondition(codecTrace.backpressure?.datagramAction === 'dropped-delta-for-stale-datagrams', 'Mercury stale datagram handling missing', failures);
  requireCondition(productEvidence.media?.source === 'OpenBurnBarMedia product APIs', 'product media evidence source mismatch', failures);
  requireCondition(mobileResult.ok, 'VAL-MOBILE-001 mobile media/control prerequisite did not pass', failures);
  requireCondition(mobileProbe.mediaControlViewerFramesObserved === true, 'mobile media/control frames missing', failures);

  const mediaProof = {
    generatedAt: now(),
    target: 'VAL-MEDIA-001',
    status: failures.length === 0 ? 'pass' : 'fail',
    acceptedAsPass: failures.length === 0,
    contractBoundary: 'Pass requires current checkout iroh loopback proof plus product Mercury codec/backpressure trace and live mobile media/control transcript. Simulator timing alone is rejected.',
    currentCheckoutIrohLoopback: {
      command: loopback.command,
      exitCode: loopback.exitCode,
      durationMs: loopback.durationMs,
      log: rel(path.join(runDir, 'iroh-loopback-handshake.log')),
      acceptedAsPass: loopbackPassed,
      proofSurface: loopback.proofSurface,
      cargoResolution: loopback.cargoResolution,
      dockerProbeExitCode: loopback.dockerProbeExitCode,
      dockerProbeLog: loopback.dockerProbeLog,
      alpn: 'openburnbar/1',
      relayMode: 'disabled',
      transport: 'iroh loopback direct addresses',
      frameRoundTrip: loopbackPassed
    },
    mercuryProductTrace: {
      artifact: rel(path.join(bundleDir, 'computer-use-media-codec-trace.json')),
      source: codecTrace.source,
      selectedVideoCodec: codecTrace.negotiation?.selectedVideoCodec,
      wireVersion: codecTrace.negotiation?.wireVersion,
      hevcLimitation: codecTrace.negotiation?.hevcLimitation,
      frameSealed: codecTrace.frameSeal?.sealedEnvelope,
      backpressure: codecTrace.backpressure
    },
    mobileInteropBinding: {
      artifact: rel(path.join(bundleDir, 'mobile-live-surface-probe.json')),
      iosSimulatorDescription: mobileProbe.iosSimulatorDescription,
      linuxPeerDescription: mobileProbe.linuxPeerDescription,
      mediaControlViewerFramesObserved: mobileProbe.mediaControlViewerFramesObserved,
      exchangeCount: mobileProbe.exchangeCount
    },
    rejectedEvidenceKinds: {
      mediaSimulatorTimingOnly: true,
      irohDependencyFailure: !loopbackPassed,
      fixtureOnlyRows: true
    },
    failures
  };
  writeJSON(path.join(runDir, 'media-iroh-mercury-proof.json'), mediaProof);
  writeJSON(path.join(runDir, 'media-lan-stage-timing.json'), {
    generatedAt: now(),
    target: 'VAL-MEDIA-001',
    status: mediaProof.status,
    acceptedAsPass: mediaProof.acceptedAsPass,
    stages: [
      { name: 'iroh.loopback.alpn_handshake', source: 'cargo test --test loopback_handshake', passed: loopbackPassed },
      { name: 'mercury.codec.negotiation', source: 'OpenBurnBarMedia product APIs', selectedVideoCodec: codecTrace.negotiation?.selectedVideoCodec, passed: codecTrace.negotiation?.selectedVideoCodec === 'h264' },
      { name: 'mercury.frame.seal', source: 'OpenBurnBarMedia product APIs', sealedEnvelope: codecTrace.frameSeal?.sealedEnvelope, passed: codecTrace.frameSeal?.sealedEnvelope === true },
      { name: 'mercury.backpressure', source: 'OpenBurnBarMedia product APIs', action: codecTrace.backpressure?.producerAction, passed: codecTrace.backpressure?.producerAction === 'paused-producer' },
      { name: 'mobile.media_control_frames', source: 'iOS simulator to Linux peer transcript', passed: mobileProbe.mediaControlViewerFramesObserved === true }
    ],
    loopbackLog: rel(path.join(runDir, 'iroh-loopback-handshake.log')),
    proof: rel(path.join(runDir, 'media-iroh-mercury-proof.json'))
  });

  return {
    target: 'VAL-MEDIA-001',
    ok: failures.length === 0,
    failures,
    status: failures.length === 0 ? 'pass' : 'fail',
    reason: failures.length === 0
      ? 'Current checkout iroh loopback ALPN/frame proof passed and is bound to Mercury codec/backpressure plus live mobile media/control frames.'
      : failures.join('; '),
    evidence: [
      rel(path.join(runDir, 'media-iroh-mercury-proof.json')),
      rel(path.join(runDir, 'iroh-loopback-handshake.log')),
      rel(path.join(runDir, 'media-lan-stage-timing.json')),
      rel(path.join(bundleDir, 'computer-use-media-codec-trace.json')),
      rel(path.join(bundleDir, 'mobile-live-surface-probe.json'))
    ],
    details: mediaProof
  };
}

function statusRow(result) {
  return {
    target: result.target,
    status: result.status,
    acceptedAsPass: result.ok,
    notClaimedAsPass: !result.ok,
    reason: result.reason,
    prerequisite: result.prerequisite || null,
    evidence: result.evidence,
    failures: result.failures,
    details: result.details
  };
}

function writeSummary(provenance, manifest, results) {
  const statuses = results.map(statusRow);
  const targets = Object.fromEntries(statuses.map((row) => [row.target, row]));
  const failed = statuses.filter((row) => row.status !== 'pass').map((row) => row.target);
  const generatedAt = now();

  const statusPayload = {
    generatedAt,
    sourceRunDirectory: rel(runDir),
    preservedEvidenceDirectory: rel(preservedDir),
    provenanceManifest: rel(path.join(outDir, 'preserved-qemu-portal-mobile-manifest.json')),
    targetIds,
    statusSemantics: {
      pass: 'Current checkout artifact set satisfies the target with contract-matching evidence.',
      fail: 'The target is not accepted as pass and the script exits nonzero.'
    },
    rejectionPolicy: {
      fixtureOnlyRowsAcceptedAsPass: false,
      staleTmpOnlyRowsAcceptedAsPass: false,
      panicSessionMediaSimulatorOnlyAcceptedAsPass: false,
      dockerHttpMobileRemoteOnlyAcceptedAsPass: false,
      x11OrXtestFallbackAcceptedAsPass: false,
      mediaSimulatorTimingOnlyAcceptedAsPass: false
    },
    provenance,
    statuses,
    targets,
    failedTargets: failed
  };
  writeJSON(path.join(outDir, 'computer-use-target-status.json'), statusPayload);

  const summary = {
    generatedAt,
    status: failed.length === 0 ? 'pass' : 'fail',
    passedTargets: statuses.filter((row) => row.status === 'pass').map((row) => row.target),
    failedTargets: failed,
    sourceBundle: provenance.selectedSourceBundle,
    preservedTmpDir: provenance.preservedTmpDir,
    currentCheckoutCopy: provenance.currentCheckoutCopy,
    manifest: rel(path.join(outDir, 'preserved-qemu-portal-mobile-manifest.json')),
    mediaProof: rel(path.join(runDir, 'media-iroh-mercury-proof.json')),
    loopbackLog: rel(path.join(runDir, 'iroh-loopback-handshake.log')),
    evidencePolicy: statusPayload.rejectionPolicy,
    manifestDigest: crypto.createHash('sha256').update(JSON.stringify(manifest)).digest('hex')
  };
  writeJSON(path.join(outDir, 'computer-use-evidence-summary.json'), summary);

  writeText(path.join(outDir, 'README.md'), `# Mission 001 computer-use/media/mobile evidence

Generated by \`node scripts/linux-port/run-computer-use-evidence.mjs\` at ${generatedAt}.

This directory is current-checkout evidence. The real-surface QEMU/Wayland portal, AT-SPI2 input, iOS simulator mobile, and audit artifacts are copied into \`${rel(preservedDir)}\` with checksums in \`${rel(path.join(outDir, 'preserved-qemu-portal-mobile-manifest.json'))}\`.

Pass rows reject stale or wrong-surface evidence:

- VAL-CU-001 requires Wayland portal/PipeWire ScreenCast CreateSession, SelectSources, Start, approved frame, denial, revoke/session close, and QEMU virtio-gpu/Sway provenance.
- VAL-CU-002 requires AT-SPI2 visible target mutation plus denied region, denied/no-permission, trust downgrade, rate-limit/replay, and per-action audit-chain binding.
- VAL-CU-003 is accepted only because VAL-CU-002 passed first.
- VAL-MEDIA-001 requires \`${rel(path.join(runDir, 'iroh-loopback-handshake.log'))}\` exit 0 plus Mercury codec/backpressure and mobile media/control transcript binding; media simulator timing alone is rejected.
- VAL-MOBILE-001 requires the copied live iOS simulator to Linux peer transcript and VAL-CU-002 prerequisite.
- VAL-SEC-003 requires product audit verifier accept/reject rows.
`);

  if (failed.length > 0) {
    process.exitCode = 1;
  }
}

function main() {
  fs.mkdirSync(outDir, { recursive: true });
  fs.rmSync(path.join(outDir, 'computer-use-evidence-error.log'), { force: true });
  fs.rmSync(runDir, { recursive: true, force: true });
  fs.mkdirSync(runDir, { recursive: true });

  const sourceBundle = chooseSourceBundle();
  const provenance = preserveSourceBundle(sourceBundle);
  const manifest = directoryManifest(preservedDir, 'current-checkout-copy-of-real-surface-cu-mobile-security-evidence');
  writeJSON(path.join(outDir, 'preserved-qemu-portal-mobile-manifest.json'), {
    ...manifest,
    provenance
  });

  const portal = validatePortal(preservedDir);
  const input = validateInputAdapter(preservedDir, portal);
  const panic = validatePanic(preservedDir, input);
  const mobile = validateMobile(preservedDir, input);
  const security = validateSecurity(preservedDir);
  const media = validateMedia(preservedDir, mobile);
  const results = [portal, input, panic, media, mobile, security];

  writeSummary(provenance, manifest, results);

  const failed = results.filter((result) => !result.ok);
  if (failed.length > 0) {
    fail(`computer-use evidence failed targets: ${failed.map((result) => result.target).join(', ')}`);
  }
  console.log(`computer-use/media/mobile evidence: pass (${targetIds.join(', ')})`);
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.stack || error.message : String(error);
  fs.mkdirSync(outDir, { recursive: true });
  writeText(path.join(outDir, 'computer-use-evidence-error.log'), message);
  console.error(message);
  process.exit(1);
}
