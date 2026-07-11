import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  buildNativeShellEvidence,
  nativeRequirementPasses,
  nativeShellEvidenceRequirements
} from './lib/native-shell-evidence.mjs';
import { repoRoot } from './lib/linux-release-common.mjs';

const verifyShellEvidence = path.join(repoRoot, 'scripts/linux-port/verify-shell-evidence.mjs');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-native-shell-evidence-'));
}

function writeText(root, fileName, text) {
  fs.writeFileSync(path.join(root, fileName), text.endsWith('\n') ? text : `${text}\n`);
}

function writeJson(root, fileName, value) {
  fs.writeFileSync(path.join(root, fileName), `${JSON.stringify(value, null, 2)}\n`);
}

function writeCompleteNativeArtifacts(root) {
  writeText(root, 'tray-registered-items.txt', "(<[':1.2/org/ayatana/NotificationItem/openburnbar']>,)");
  writeText(root, 'tray-status-notifier-introspection.txt', 'interface org.kde.StatusNotifierItem { readonly o Menu = \'/Menu\'; };');
  writeJson(root, 'tray-menu-actions.json', {
    actions: [
      { label: 'Open dashboard' },
      { label: 'Open chat' },
      { label: 'Open providers' },
      { label: 'Check updates' },
      { label: 'Reconnect daemon' },
      { label: 'Start at login' },
      { label: 'Quit OpenBurnBar' }
    ]
  });
  for (const fileName of [
    'tray-open-menu-event.txt',
    'tray-chat-menu-event.txt',
    'tray-providers-menu-event.txt',
    'tray-updates-menu-event.txt',
    'tray-reconnect-menu-event.txt',
    'tray-login-start-menu-event.txt',
    'tray-quit-menu-event.txt'
  ]) {
    writeText(root, fileName, 'method return');
  }
  writeJson(root, 'tray-action-route-results.json', {
    passed: true,
    actions: {
      openDashboard: { passed: true, route: 'overview', action: 'open-dashboard' },
      openChat: { passed: true, route: 'chat', action: 'open-chat' },
      openProviders: { passed: true, route: 'providers', action: 'open-providers' },
      openUpdates: { passed: true, route: 'updates', action: 'open-updates' },
      reconnectDaemon: { passed: true, route: 'support', action: 'reconnect-daemon' },
      loginStart: { passed: true, enabled: true, disabled: true },
      quit: { passed: true, exited: true }
    }
  });
  writeJson(root, 'native-status-window-report.json', { passed: true });
  fs.writeFileSync(path.join(root, 'screenshot-native-status-window.png'), Buffer.alloc(512, 1));
  writeJson(root, 'native-status-window-a11y.json', {
    passed: true,
    keyboard: true,
    assistiveTechnology: true
  });
  writeJson(root, 'native-notification-capabilities.json', {
    available: true,
    serverName: 'mako'
  });
  writeJson(root, 'native-notification-action-result.json', {
    passed: true,
    delivered: true,
    actionsAttached: true,
    route: 'chat',
    action: 'open-chat'
  });
  writeJson(root, 'native-notification-relaunch-route.json', {
    passed: true,
    focusedExistingWindow: true,
    route: 'chat'
  });
  writeJson(root, 'native-deep-link-relaunch.json', {
    passed: true,
    sameProcess: true,
    route: 'chat'
  });
  writeJson(root, 'native-global-panic-shortcut-response.json', {
    passed: true,
    daemonAccepted: true,
    source: 'hotkey',
    chord: 'Ctrl+Alt+Shift+Period',
    sessionId: '*',
    endedAtPresent: true,
    auditHeadPresent: true,
    result: {
      sessionId: '*',
      endedAt: 1234,
      auditHeadHashHex: ''
    }
  });
  writeJson(root, 'native-global-panic-shortcut.json', {
    passed: true,
    appWindowFocused: false,
    foregroundProbeFocused: true,
    chord: 'Ctrl+Alt+Shift+Period'
  });
  writeJson(root, 'native-login-start-roundtrip.json', {
    passed: true,
    enabled: true,
    disabled: true,
    relogin: true,
    staleFileReplaced: true,
    uninstallRemoved: true,
    uninstallScope: 'package-owned-autostart-reference',
    finalEnabled: true,
    userAutostartPreserved: true
  });
  writeJson(root, 'native-login-start-relogin.json', {
    passed: true,
    sameProcess: true,
    routeSampleObserved: true,
    route: 'chat',
    action: 'open-chat'
  });
  writeJson(root, 'tray-host-loss-recovery.json', {
    passed: true,
    hostLost: true,
    recovered: true,
    staleActions: false,
    processCount: 1,
    actionAfterRecovery: {
      passed: true,
      route: 'chat',
      action: 'open-chat'
    }
  });
}

test('native shell evidence builder reports partial installed artifacts honestly', () => {
  const root = tempDir();
  try {
    writeText(root, 'tray-registered-items.txt', "(<[':1.2/org/ayatana/NotificationItem/openburnbar']>,)");
    writeText(root, 'tray-status-notifier-introspection.txt', 'interface org.kde.StatusNotifierItem { readonly o Menu = \'/Menu\'; };');

    const evidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'abc123',
      environmentId: 'ubuntu-24.04-gnome-x11-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });

    assert.equal(evidence.passed, false);
    assert.equal(evidence.nativeShell.trayHost, true);
    assert.equal(evidence.nativeShell.trayActions, false);
    assert.ok(evidence.missing.includes('notification-actions'));
    assert.ok(evidence.missing.includes('tray-host-loss-recovery'));
    assert.equal(evidence.git.commit, 'abc123');
    assert.equal(evidence.environmentId, 'ubuntu-24.04-gnome-x11-x86_64');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('complete native shell evidence satisfies every matrix requirement alias', () => {
  const root = tempDir();
  try {
    writeCompleteNativeArtifacts(root);
    const evidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'def456',
      environmentId: 'fedora-kde-wayland-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });

    assert.equal(evidence.passed, true);
    assert.deepEqual(evidence.missing, []);
    for (const requirement of nativeShellEvidenceRequirements) {
      assert.equal(evidence.nativeShell[requirement.key], true, requirement.id);
      assert.equal(nativeRequirementPasses(evidence, requirement), true, requirement.id);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('partial login-start lifecycle artifact remains blocked', () => {
  const root = tempDir();
  try {
    writeCompleteNativeArtifacts(root);
    writeJson(root, 'native-login-start-roundtrip.json', {
      passed: false,
      enabled: true,
      disabled: true,
      relogin: false,
      staleFileReplaced: true,
      uninstallRemoved: false
    });

    const evidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'def456',
      environmentId: 'fedora-kde-wayland-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });

    assert.equal(evidence.passed, false);
    assert.equal(evidence.nativeShell.loginStart, false);
    assert.ok(evidence.missing.includes('login-start'));
    const loginCheck = evidence.checks.find((check) => check.id === 'login-start');
    assert.match(loginCheck?.detail ?? '', /missing complete login-start lifecycle proof/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('tray host recovery artifact rejects stale or duplicate actions', () => {
  const root = tempDir();
  try {
    writeCompleteNativeArtifacts(root);
    writeJson(root, 'tray-host-loss-recovery.json', {
      passed: false,
      recovered: true,
      staleActions: true,
      hostLossObserved: true,
      recoveryRegistered: true,
      recoveredAction: true,
      registeredItemCountAfterRecovery: 2,
      processCount: 1,
      windowCount: 1
    });

    const evidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'def456',
      environmentId: 'fedora-kde-wayland-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });

    assert.equal(evidence.passed, false);
    assert.equal(evidence.nativeShell.trayHostLossRecovery, false);
    assert.ok(evidence.missing.includes('tray-host-loss-recovery'));
    const recoveryCheck = evidence.checks.find((check) => check.id === 'tray-host-loss-recovery');
    assert.match(recoveryCheck?.detail ?? '', /missing tray host loss recovery proof/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('global panic shortcut rejects direct RPC or app-focused evidence', () => {
  const root = tempDir();
  try {
    writeCompleteNativeArtifacts(root);
    writeJson(root, 'native-global-panic-shortcut.json', {
      passed: true,
      appWindowFocused: true,
      foregroundProbeFocused: false,
      chord: 'Ctrl+Alt+Shift+Period'
    });

    const evidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'def456',
      environmentId: 'ubuntu-24.04-gnome-x11-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });

    assert.equal(evidence.passed, false);
    assert.equal(evidence.nativeShell.globalPanicShortcut, false);
    assert.ok(evidence.missing.includes('global-panic-shortcut'));
    const panicCheck = evidence.checks.find((check) => check.id === 'global-panic-shortcut');
    assert.match(panicCheck?.detail ?? '', /missing installed global panic shortcut/);

    writeJson(root, 'native-global-panic-shortcut-response.json', {
      passed: true,
      daemonAccepted: true,
      source: 'hotkey',
      chord: 'Ctrl+Alt+F13',
      sessionId: '*',
      endedAtPresent: true,
      auditHeadPresent: true,
      result: { sessionId: '*', endedAt: 1234, auditHeadHashHex: '' }
    });
    writeJson(root, 'native-global-panic-shortcut.json', {
      passed: true,
      appWindowFocused: false,
      foregroundProbeFocused: true,
      chord: 'Ctrl+Alt+F13'
    });
    const wrongChordEvidence = buildNativeShellEvidence({
      evidenceDir: root,
      commit: 'def456',
      environmentId: 'ubuntu-24.04-gnome-x11-x86_64',
      generatedAt: '2026-07-10T00:00:00.000Z'
    });
    assert.equal(wrongChordEvidence.nativeShell.globalPanicShortcut, false);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('shell evidence verifier emits native-shell-evidence.json for matrix consumption', () => {
  const root = tempDir();
  try {
    writeText(root, 'tray-registered-items.txt', "(<[':1.2/org/ayatana/NotificationItem/openburnbar']>,)");
    writeText(root, 'tray-status-notifier-introspection.txt', 'interface org.kde.StatusNotifierItem { readonly o Menu = \'/Menu\'; };');

    const result = spawnSync(process.execPath, [verifyShellEvidence, root, 'json'], {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        OB_LINUX_ENVIRONMENT_ID: 'ubuntu-24.04-gnome-wayland-x86_64'
      }
    });

    assert.equal(result.status, 1);
    const nativeEvidence = JSON.parse(fs.readFileSync(path.join(root, 'native-shell-evidence.json'), 'utf8'));
    assert.equal(nativeEvidence.environmentId, 'ubuntu-24.04-gnome-wayland-x86_64');
    assert.equal(nativeEvidence.nativeShell.trayHost, true);
    assert.equal(nativeEvidence.passed, false);

    const verification = JSON.parse(fs.readFileSync(path.join(root, 'shell-evidence-verify.json'), 'utf8'));
    assert.equal(verification.nativeShellEvidence.passed, false);
    assert.ok(verification.nativeShellEvidence.path.endsWith('native-shell-evidence.json'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
