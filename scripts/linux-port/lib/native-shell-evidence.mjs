import fs from 'node:fs';
import path from 'node:path';

export const nativeShellEvidenceRequirements = [
  {
    id: 'tray-host',
    key: 'trayHost',
    keys: ['trayHost', 'tray-host'],
    description: 'StatusNotifier/AppIndicator host renders the installed tray affordance'
  },
  {
    id: 'tray-actions',
    key: 'trayActions',
    keys: ['trayActions', 'tray-actions'],
    description: 'Tray dashboard/chat/provider/update/reconnect/login-start/quit actions route correctly'
  },
  {
    id: 'compact-status-window',
    key: 'compactStatusWindow',
    keys: ['compactStatusWindow', 'compact-status-window'],
    description: 'Compact native status window opens, refreshes, and closes without mounting the full shell'
  },
  {
    id: 'status-window-a11y',
    key: 'statusWindowAccessibility',
    keys: ['statusWindowAccessibility', 'statusWindowA11y', 'status-window-a11y'],
    description: 'Compact status window is keyboard and assistive-technology reachable'
  },
  {
    id: 'notification-server',
    key: 'notificationServer',
    keys: ['notificationServer', 'notification-server'],
    description: 'Freedesktop notification server capability is detected honestly'
  },
  {
    id: 'notification-actions',
    key: 'notificationActions',
    keys: ['notificationActions', 'notification-actions'],
    description: 'Notification actions deliver only allowlisted native route/action pairs'
  },
  {
    id: 'notification-relaunch-route',
    key: 'notificationRelaunchRoute',
    keys: ['notificationRelaunchRoute', 'notification-relaunch-route'],
    description: 'Notification activation relaunches or focuses the installed app and routes correctly'
  },
  {
    id: 'deep-link-relaunch',
    key: 'deepLinkRelaunch',
    keys: ['deepLinkRelaunch', 'deep-link-relaunch'],
    description: 'Secondary openburnbar:// launches reuse the existing instance and route correctly'
  },
  {
    id: 'global-panic-shortcut',
    key: 'globalPanicShortcut',
    keys: ['globalPanicShortcut', 'global-panic-shortcut'],
    description: 'The installed global panic chord reaches the daemon-wide kill path while another app has focus'
  },
  {
    id: 'login-start',
    key: 'loginStart',
    keys: ['loginStart', 'login-start'],
    description: 'XDG login-start enable, relogin, disable, stale-file, and uninstall paths are proven'
  },
  {
    id: 'tray-host-loss-recovery',
    key: 'trayHostLossRecovery',
    keys: ['trayHostLossRecovery', 'hostLossRecovery', 'tray-host-loss-recovery'],
    description: 'Tray host loss/crash/restart recovers without stale status or orphaned actions'
  }
];

export function passedValue(value) {
  if (value === true) return true;
  if (!value || typeof value !== 'object') return false;
  return (
    value.passed === true ||
    value.ok === true ||
    value.status === 'passed' ||
    value.result === 'passed'
  );
}

export function nativeEvidenceSources(evidence) {
  return [
    evidence.nativeShell,
    evidence.native_shell,
    evidence.capabilities?.nativeShell,
    evidence.capabilities?.native_shell,
    evidence.capabilities,
    evidence
  ].filter((source) => source && typeof source === 'object' && !Array.isArray(source));
}

export function nativeEvidenceChecks(evidence) {
  return nativeEvidenceSources(evidence)
    .flatMap((source) => (Array.isArray(source.checks) ? source.checks : []))
    .filter((check) => check && typeof check === 'object');
}

export function nativeRequirementPasses(evidence, requirement) {
  const identifiers = [requirement.id, ...requirement.keys];
  const directPass = nativeEvidenceSources(evidence).some((source) =>
    identifiers.some((identifier) => passedValue(source[identifier]))
  );
  if (directPass) return true;
  return nativeEvidenceChecks(evidence).some((check) => {
    const id = String(check.id ?? check.name ?? check.capability ?? '').trim();
    return identifiers.includes(id) && passedValue(check);
  });
}

export function evidenceCommit(evidence) {
  return evidence.git?.commit ?? evidence.commit ?? null;
}

export function evidenceEnvironmentId(evidence) {
  return evidence.environmentId ?? evidence.environment?.id ?? evidence.environment?.environmentId ?? null;
}

function fileText(evidenceDir, fileName) {
  const full = path.join(evidenceDir, fileName);
  if (!fs.existsSync(full)) return null;
  return fs.readFileSync(full, 'utf8');
}

function fileJson(evidenceDir, fileName) {
  const text = fileText(evidenceDir, fileName);
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function fileHasBytes(evidenceDir, fileName, minimumBytes = 1) {
  const full = path.join(evidenceDir, fileName);
  return fs.existsSync(full) && fs.statSync(full).isFile() && fs.statSync(full).size >= minimumBytes;
}

function result(id, passed, detail, artifacts = []) {
  return { id, passed, detail, artifacts };
}

function jsonPass(value) {
  return value?.passed === true || value?.pass === true || value?.ok === true || value?.status === 'passed';
}

function evaluateTrayHost(evidenceDir) {
  const registered = fileText(evidenceDir, 'tray-registered-items.txt') ?? '';
  const introspection = fileText(evidenceDir, 'tray-status-notifier-introspection.txt') ?? '';
  const passed = registered.includes('NotificationItem') &&
    introspection.includes('org.kde.StatusNotifierItem') &&
    introspection.includes('Menu =');
  return result(
    'tray-host',
    passed,
    passed ? 'status notifier item and menu path exported' : 'missing StatusNotifierItem registration or menu path',
    ['tray-registered-items.txt', 'tray-status-notifier-introspection.txt']
  );
}

function evaluateTrayActions(evidenceDir) {
  const actions = fileJson(evidenceDir, 'tray-menu-actions.json');
  const routeResults = fileJson(evidenceDir, 'tray-action-route-results.json');
  const labels = new Set((actions?.actions ?? []).map((action) => action.label));
  const requiredLabels = [
    'Open dashboard',
    'Open chat',
    'Open providers',
    'Check updates',
    'Reconnect daemon',
    'Start at login',
    'Quit OpenBurnBar'
  ];
  const missingLabels = requiredLabels.filter((label) => !labels.has(label));
  const eventFiles = [
    'tray-open-menu-event.txt',
    'tray-chat-menu-event.txt',
    'tray-providers-menu-event.txt',
    'tray-updates-menu-event.txt',
    'tray-reconnect-menu-event.txt',
    'tray-login-start-menu-event.txt',
    'tray-quit-menu-event.txt'
  ];
  const missingEvents = eventFiles.filter((fileName) => !(fileText(evidenceDir, fileName) ?? '').includes('method return'));
  const requiredResults = [
    'openDashboard',
    'openChat',
    'openProviders',
    'openUpdates',
    'reconnectDaemon',
    'loginStart',
    'quit'
  ];
  const missingResults = requiredResults.filter((key) => routeResults?.actions?.[key]?.passed !== true);
  const passed = missingLabels.length === 0 &&
    missingEvents.length === 0 &&
    jsonPass(routeResults) &&
    missingResults.length === 0;
  return result(
    'tray-actions',
    passed,
    passed
      ? 'all native tray actions returned through D-Bus and produced installed-session outcomes'
      : `missing labels=${missingLabels.join(',') || 'none'} missing events=${missingEvents.join(',') || 'none'} missing results=${missingResults.join(',') || 'none'}`,
    ['tray-menu-actions.json', 'tray-action-route-results.json', ...eventFiles]
  );
}

function evaluateCompactStatusWindow(evidenceDir) {
  const report = fileJson(evidenceDir, 'native-status-window-report.json');
  const screenshot = fileHasBytes(evidenceDir, 'screenshot-native-status-window.png', 256);
  const passed = jsonPass(report) && screenshot;
  return result(
    'compact-status-window',
    passed,
    passed ? 'compact status report and screenshot captured' : 'missing compact status report or screenshot',
    ['native-status-window-report.json', 'screenshot-native-status-window.png']
  );
}

function evaluateStatusWindowA11y(evidenceDir) {
  const a11y = fileJson(evidenceDir, 'native-status-window-a11y.json');
  const passed = jsonPass(a11y) && a11y?.keyboard === true && a11y?.assistiveTechnology === true;
  return result(
    'status-window-a11y',
    passed,
    passed ? 'compact status keyboard and assistive-technology evidence passed' : 'missing compact status accessibility proof',
    ['native-status-window-a11y.json']
  );
}

function evaluateNotificationServer(evidenceDir) {
  const capabilities = fileJson(evidenceDir, 'native-notification-capabilities.json');
  const passed = capabilities?.available === true && typeof capabilities.serverName === 'string';
  return result(
    'notification-server',
    passed,
    passed ? `notification server available: ${capabilities.serverName}` : 'missing freedesktop notification server capability',
    ['native-notification-capabilities.json']
  );
}

function evaluateNotificationActions(evidenceDir) {
  const action = fileJson(evidenceDir, 'native-notification-action-result.json');
  const passed = jsonPass(action) &&
    action?.delivered === true &&
    action?.actionsAttached === true &&
    typeof action?.route === 'string' &&
    typeof action?.action === 'string';
  return result(
    'notification-actions',
    passed,
    passed ? 'notification action delivered an allowlisted route/action pair' : 'missing notification action delivery proof',
    ['native-notification-action-result.json']
  );
}

function evaluateNotificationRelaunch(evidenceDir) {
  const relaunch = fileJson(evidenceDir, 'native-notification-relaunch-route.json');
  const passed = jsonPass(relaunch) && relaunch?.focusedExistingWindow === true && typeof relaunch?.route === 'string';
  return result(
    'notification-relaunch-route',
    passed,
    passed ? 'notification activation focused existing window and routed' : 'missing notification relaunch route proof',
    ['native-notification-relaunch-route.json']
  );
}

function evaluateDeepLinkRelaunch(evidenceDir) {
  const relaunch = fileJson(evidenceDir, 'native-deep-link-relaunch.json');
  const passed = jsonPass(relaunch) && relaunch?.sameProcess === true && typeof relaunch?.route === 'string';
  return result(
    'deep-link-relaunch',
    passed,
    passed ? 'secondary openburnbar:// launch reused existing process and routed' : 'missing deep-link relaunch proof',
    ['native-deep-link-relaunch.json']
  );
}

function evaluateGlobalPanicShortcut(evidenceDir) {
  const response = fileJson(evidenceDir, 'native-global-panic-shortcut-response.json');
  const report = fileJson(evidenceDir, 'native-global-panic-shortcut.json');
  const allowedChords = new Set(['Ctrl+Alt+Super+Period', 'Ctrl+Alt+Shift+Period']);
  const passed = jsonPass(response) &&
    jsonPass(report) &&
    response?.daemonAccepted === true &&
    response?.source === 'hotkey' &&
    response?.sessionId === '*' &&
    response?.endedAtPresent === true &&
    response?.auditHeadPresent === true &&
    response?.result?.sessionId === '*' &&
    response?.result?.endedAt !== undefined &&
    typeof response?.result?.auditHeadHashHex === 'string' &&
    allowedChords.has(response?.chord) &&
    report?.appWindowFocused === false &&
    report?.foregroundProbeFocused === true &&
    report?.chord === response?.chord;
  return result(
    'global-panic-shortcut',
    passed,
    passed
      ? 'global panic chord reached the daemon-wide kill path while the probe window held focus'
      : 'missing installed global panic shortcut focus and daemon-acceptance proof',
    ['native-global-panic-shortcut-response.json', 'native-global-panic-shortcut.json']
  );
}

function evaluateLoginStart(evidenceDir) {
  const loginStart = fileJson(evidenceDir, 'native-login-start-roundtrip.json');
  const passed = jsonPass(loginStart) &&
    loginStart?.enabled === true &&
    loginStart?.disabled === true &&
    loginStart?.relogin === true &&
    loginStart?.staleFileReplaced === true &&
    loginStart?.uninstallRemoved === true;
  return result(
    'login-start',
    passed,
    passed ? 'login-start lifecycle passed' : 'missing complete login-start lifecycle proof',
    ['native-login-start-roundtrip.json']
  );
}

function evaluateTrayHostLossRecovery(evidenceDir) {
  const recovery = fileJson(evidenceDir, 'tray-host-loss-recovery.json');
  const passed = jsonPass(recovery) &&
    recovery?.hostLost === true &&
    recovery?.recovered === true &&
    recovery?.staleActions === false &&
    recovery?.actionAfterRecovery?.passed === true &&
    recovery?.processCount === 1;
  return result(
    'tray-host-loss-recovery',
    passed,
    passed ? 'tray host loss recovered without stale actions' : 'missing tray host loss recovery proof',
    ['tray-host-loss-recovery.json']
  );
}

const artifactEvaluators = new Map([
  ['tray-host', evaluateTrayHost],
  ['tray-actions', evaluateTrayActions],
  ['compact-status-window', evaluateCompactStatusWindow],
  ['status-window-a11y', evaluateStatusWindowA11y],
  ['notification-server', evaluateNotificationServer],
  ['notification-actions', evaluateNotificationActions],
  ['notification-relaunch-route', evaluateNotificationRelaunch],
  ['deep-link-relaunch', evaluateDeepLinkRelaunch],
  ['global-panic-shortcut', evaluateGlobalPanicShortcut],
  ['login-start', evaluateLoginStart],
  ['tray-host-loss-recovery', evaluateTrayHostLossRecovery]
]);

export function buildNativeShellEvidence({ evidenceDir, commit, environmentId, generatedAt = new Date().toISOString() }) {
  const checks = nativeShellEvidenceRequirements.map((requirement) => {
    const check = artifactEvaluators.get(requirement.id)?.(evidenceDir) ??
      result(requirement.id, false, 'no artifact evaluator registered', []);
    return { ...check, description: requirement.description };
  });
  const nativeShell = Object.fromEntries(
    nativeShellEvidenceRequirements.map((requirement) => [
      requirement.key,
      checks.find((check) => check.id === requirement.id)?.passed === true
    ])
  );
  const missing = checks.filter((check) => !check.passed).map((check) => check.id);
  return {
    schemaVersion: 1,
    generatedAt,
    passed: missing.length === 0,
    git: { commit },
    environmentId: environmentId ?? null,
    evidenceDir,
    nativeShell,
    checks,
    missing
  };
}
