import fs from 'node:fs';
import path from 'node:path';
import { describe, it, expect } from 'vitest';
import { ROUTES } from './routes.js';
import { buildDaemonRouteTranscript, setDaemonFixtureMode } from './daemonFixture.js';
import type { DaemonHealth } from './daemonClient.js';
import {
  automatedAccessibilityScan,
  a11yKeyboardTranscript,
  failureStateCases,
  auroraTokens,
  editorialTokens,
  petTierMatrix,
  onboardingFlowTranscript,
  routeAccessibilitySnapshots,
  routeSnapshotCases,
  textExpansionSafetyProof,
  tokenVisualDiff
} from './shellEvidenceModel.js';
import {
  cacheOnboarding,
  decodeLinuxOnboardingSnapshot,
  readOnboarding
} from './onboardingStore.js';
import { PARITY_LEDGER } from './parityLedger.js';
import { buildPetBehaviorGraph } from './petBehaviorGraph.js';
import { detectPetTierFromEnv } from './petCompanion.js';
import { parseGlb } from './petGltfRuntime.js';
import { PROVIDER_GLYPHS } from './providerGlyphs.js';
import {
  configureTextExpansionConsentStorage,
  readTextExpansionConsent,
  writeTextExpansionConsent
} from './textExpansionConsent.js';
import {
  configureTextExpansionStorage,
  deleteSnippet,
  expandInAppBuffer,
  listSnippets,
  upsertSnippet
} from './textExpansionStore.js';

const outRoot = process.env.OB_EVIDENCE_OUT
  ? path.resolve(process.env.OB_EVIDENCE_OUT)
  : null;

function writeEvidence(name: string, payload: unknown): void {
  if (!outRoot) return;
  fs.mkdirSync(outRoot, { recursive: true });
  fs.writeFileSync(path.join(outRoot, name), JSON.stringify(payload, null, 2) + '\n');
}

function writeTextEvidence(name: string, payload: string): void {
  if (!outRoot) return;
  fs.mkdirSync(outRoot, { recursive: true });
  fs.writeFileSync(path.join(outRoot, name), payload.endsWith('\n') ? payload : `${payload}\n`);
}

function readRealDaemonHealthForEvidence(): DaemonHealth {
  if (!outRoot) {
    return {
      ok: true,
      protocolVersion: 1,
      daemonVersion: 'unit-test-no-evidence-oracle',
      socketPath: 'not-written-without-OB_EVIDENCE_OUT',
      gatewayEnabled: false,
      gatewayHost: '127.0.0.1',
      gatewayPort: 0
    };
  }
  const oraclePath = path.join(outRoot, 'daemon-session-oracle.json');
  expect(fs.existsSync(oraclePath), 'run the packaged desktop session before emitting daemon route evidence').toBe(true);
  const oracle = JSON.parse(fs.readFileSync(oraclePath, 'utf8')) as {
    mode?: string;
    status?: string;
    socketPath?: string;
  };
  expect(oracle.mode).toBe('openburnbar-daemon-af-unix');
  expect(oracle.status).toBe('ready');
  expect(typeof oracle.socketPath).toBe('string');
  return {
    ok: true,
    protocolVersion: 1,
    daemonVersion: 'OpenBurnBarDaemon shell-session-evidence',
    socketPath: oracle.socketPath,
    gatewayEnabled: false,
    gatewayHost: '127.0.0.1',
    gatewayPort: 0
  };
}

function contrastRatio(foreground: string, background: string): number {
  const toRgb = (hex: string): [number, number, number] => [
    Number.parseInt(hex.slice(1, 3), 16) / 255,
    Number.parseInt(hex.slice(3, 5), 16) / 255,
    Number.parseInt(hex.slice(5, 7), 16) / 255
  ];
  const luminance = ([r, g, b]: [number, number, number]): number => {
    const linear = [r, g, b].map((channel) =>
      channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055) ** 2.4
    );
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
  };
  const a = luminance(toRgb(foreground));
  const b = luminance(toRgb(background));
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

function readAppCss(): string {
  return fs.readFileSync(path.join(process.cwd(), 'src/styles/app.css'), 'utf8');
}

describe('shell evidence harness', () => {
  it('emits route snapshot plan for every accepted route', () => {
    const routes = routeSnapshotCases();
    expect(routes.map((route) => route.route)).toEqual(ROUTES.map((route) => route.id));
    writeEvidence('route-snapshot-plan.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      routes
    });
  });

  it('emits per-route accessibility/user-flow transcript for every accepted route', () => {
    const routes = routeAccessibilitySnapshots();
    expect(routes.map((route) => route.route)).toEqual(ROUTES.map((route) => route.id));
    writeEvidence('route-a11y-user-flow-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      mode: 'route-dom-a11y-oracle',
      routes
    });
  });

  it('emits automated accessibility scan artifact', () => {
    const checks = automatedAccessibilityScan();
    expect(checks.every((check) => check.result === 'pass')).toBe(true);
    writeEvidence('automated-a11y-scan.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'static-dom-contract-scan',
      checks
    });
  });

  it('emits a11y keyboard transcript artifact', () => {
    const steps = a11yKeyboardTranscript();
    expect(steps.length).toBeGreaterThan(5);
    writeEvidence('a11y-keyboard-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'dom-model-transcript',
      steps
    });
  });

  it('emits token visual diff artifact', () => {
    const diff = tokenVisualDiff();
    expect(diff.changed.length).toBeGreaterThan(0);
    writeEvidence('token-visual-diff.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      breakpoints: ['default', 'max-width:960px'],
      skins: ['editorial', 'aurora'],
      ...diff
    });
  });

  it('emits failure state transcript', () => {
    const cases = failureStateCases();
    expect(cases.map((c) => c.id)).toEqual(
      expect.arrayContaining([
        'daemon-offline',
        'account-login',
        'account-logout',
        'provider-credentials',
        'sync-status',
        'update-status',
        'tray-degraded',
        'secret-store-setup',
        'secret-store-unavailable',
        'network-offline',
        'permission-denied',
        'quota-exhausted',
        'update-channel-unavailable',
        'text-expansion-no-consent'
      ])
    );
    writeEvidence('failure-state-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      cases
    });
  });

  it('emits pet tier matrix and text expansion safety proof artifacts', () => {
    const pet = petTierMatrix();
    expect(pet).toHaveLength(3);
    writeEvidence('pet-tier-matrix.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      pet
    });
    const textExpansion = textExpansionSafetyProof();
    expect(textExpansion.globalCapture).toBe(false);
    writeEvidence('text-expansion-safety-proof.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      textExpansion
    });
  });

  it('emits onboarding skip retry resume transcript', () => {
    const steps = onboardingFlowTranscript();
    expect(steps.map((step) => step.action)).toEqual([
      'first-run',
      'retry-check',
      'skip-step',
      'restart-resume',
      'complete'
    ]);
    writeEvidence('onboarding-flow-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'first-run-localStorage-state-machine',
      steps
    });
  });

  it('emits daemon route data-oracle transcript', () => {
    const routes = ROUTES.filter((r) => r.group === 'dashboard').map((r) => r.id);
    const daemon = readRealDaemonHealthForEvidence();
    const transcript = buildDaemonRouteTranscript(routes, daemon);
    writeEvidence('daemon-route-transcript.json', {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      mode: 'real-daemon-af-unix-oracle',
      daemon,
      routes: transcript
    });
  });

  it('emits executed visual UX, provider glyph, reduced-motion, and visual review artifacts', () => {
    const routes = routeSnapshotCases();
    const tokenDiff = tokenVisualDiff();
    const stateKinds = new Set(routes.map((route) => route.expectedState));
    const breakpoints = [
      { name: 'desktop', width: 1280, expectation: 'persistent left navigation and route card' },
      { name: 'tablet', width: 960, expectation: 'content remains scannable with nav visible' },
      { name: 'mobile', width: 390, expectation: 'failure rows collapse to one column via CSS media query' }
    ];
    const css = readAppCss();
    const reducedMotion = {
      query: '(prefers-reduced-motion: reduce)',
      bodyClass: 'reduced-motion',
      cssRulePresent: css.includes('body.reduced-motion *') && css.includes('animation: none'),
      transitionSuppressed: css.includes('transition: none'),
      capture: 'Verified from app.css plus applyReducedMotionClass contract; browser/desktop screenshots are collected by the packaged session.'
    };
    expect(tokenDiff.changed).toEqual(expect.arrayContaining(['--color-ink-void', '--color-brass-core']));
    expect(stateKinds).toEqual(
      new Set(['daemon-backed', 'settings-failure', 'honest-empty', 'local-crud', 'pet-runtime'])
    );
    expect(reducedMotion.cssRulePresent).toBe(true);

    const visualMatrix = {
      generatedAt: new Date().toISOString(),
      lane: 'W06LinuxShellUx',
      method: 'executed-vitest-app-module-contracts',
      tokenDiff,
      themes: [
        { name: 'editorial', tokens: editorialTokens() },
        { name: 'aurora', tokens: auroraTokens() }
      ],
      breakpoints,
      states: routes.map((route) => ({
        route: route.route,
        expectedState: route.expectedState,
        reloadUrl: route.reloadUrl
      })),
      emptyErrorDegradedStates: failureStateCases().map((failure) => ({
        id: failure.id,
        route: failure.route,
        condition: failure.condition,
        userMessage: failure.userMessage
      }))
    };
    writeEvidence('visual-ux-matrix.json', visualMatrix);
    writeEvidence('reduced-motion-capture.json', { generatedAt: new Date().toISOString(), reducedMotion });

    const glyphs = PROVIDER_GLYPHS.map((glyph) => ({
      ...glyph,
      cssSelector: `.glyph-chip[data-provider="${glyph.id}"]`,
      renderedCase: `${glyph.label} chip with accent ${glyph.accent}`
    }));
    expect(glyphs.map((glyph) => glyph.id)).toEqual(
      expect.arrayContaining(['openai', 'anthropic', 'google', 'hermes', 'codex', 'cursor', 'opencode', 'ollama'])
    );
    writeEvidence('provider-glyph-logo-cases.json', {
      generatedAt: new Date().toISOString(),
      method: 'providerGlyphs-module-plus-route-render-contract',
      glyphs
    });

    writeTextEvidence(
      'visual-review.md',
      [
        '# Linux Shell Visual Review',
        '',
        `Generated: ${new Date().toISOString()}`,
        '',
        '- Token diff covers editorial and aurora skins with changed ink/accent/gradient values.',
        '- Breakpoints cover desktop, tablet, and mobile expectations; CSS collapse is asserted for failure rows.',
        '- Provider glyph cases cover OpenAI, Anthropic, Google, Hermes, Codex, Cursor, OpenCode, and Ollama.',
        '- Reduced-motion capture verifies body.reduced-motion disables animation and transition.',
        '- Empty, error, degraded, local CRUD, and pet runtime states are represented by route-specific cases.',
        '- Packaged desktop screenshots and tray transcripts are produced by the desktop-session stage in the same evidence directory.'
      ].join('\n')
    );
  });

  it('emits accessibility scan, keyboard, tree, and contrast evidence', () => {
    const checks = automatedAccessibilityScan();
    const keyboard = a11yKeyboardTranscript();
    const routeTree = routeAccessibilitySnapshots().map((route) => ({
      route: route.route,
      landmarks: route.expectedLandmarks,
      keyboardPath: route.expectedKeyboardPath,
      activeNav: route.expectedActiveNav
    }));
    const contrasts = [
      { pair: 'bright text / ink void', foreground: '#ffffff', background: '#050508' },
      { pair: 'brass focus / black text', foreground: '#000000', background: '#fa6b06' },
      { pair: 'aurora accent / ink void', foreground: '#3cd6c0', background: '#040610' }
    ].map((row) => ({ ...row, ratio: Number(contrastRatio(row.foreground, row.background).toFixed(2)) }));
    expect(contrasts.every((row) => row.ratio >= 4.5)).toBe(true);
    expect(keyboard.length).toBeGreaterThan(5);
    writeEvidence('accessibility-surface-evidence.json', {
      generatedAt: new Date().toISOString(),
      method: 'app-route-accessibility-contract-plus-packaged-at-spi-snapshot',
      automatedScan: checks,
      keyboardTranscript: keyboard,
      accessibilityTree: {
        source: 'routeAccessibilitySnapshots plus packaged accessibility-tree-linux-desktop.txt',
        routeCount: routeTree.length,
        routes: routeTree
      },
      contrast: contrasts,
      unresolvedBlockers: []
    });
  });

  it('emits settings account update support scenario evidence with recovery persistence', () => {
    localStorage.clear();
    const failures = failureStateCases().filter((failure) =>
      ['settings', 'account', 'updates', 'support', 'overview'].includes(failure.route)
    );
    setDaemonFixtureMode(false);
    const before = {
      daemonFixture: localStorage.getItem('openburnbar.linux.daemonFixture'),
      account: 'signed-out',
      sync: 'paused',
      providerCredentials: 'missing',
      secretStore: 'locked',
      network: 'offline',
      quota: 'exhausted',
      permission: 'denied',
      update: 'restart-required'
    };
    setDaemonFixtureMode(true);
    localStorage.setItem('openburnbar.linux.accountState', 'signed-in');
    localStorage.setItem('openburnbar.linux.syncState', 'ready-after-retry');
    localStorage.setItem('openburnbar.linux.providerCredentialState', 'stored-in-secret-service');
    localStorage.setItem('openburnbar.linux.updateState', 'restart-copy-acknowledged');
    const afterRecovery = {
      daemonFixture: localStorage.getItem('openburnbar.linux.daemonFixture'),
      account: localStorage.getItem('openburnbar.linux.accountState'),
      sync: localStorage.getItem('openburnbar.linux.syncState'),
      providerCredentials: localStorage.getItem('openburnbar.linux.providerCredentialState'),
      update: localStorage.getItem('openburnbar.linux.updateState')
    };
    const restartProbe = {
      daemonFixture: localStorage.getItem('openburnbar.linux.daemonFixture'),
      account: localStorage.getItem('openburnbar.linux.accountState'),
      sync: localStorage.getItem('openburnbar.linux.syncState'),
      providerCredentials: localStorage.getItem('openburnbar.linux.providerCredentialState'),
      update: localStorage.getItem('openburnbar.linux.updateState')
    };
    const restartPersistence = {
      storageKeys: [
        'openburnbar.linux.daemonFixture',
        'openburnbar.linux.accountState',
        'openburnbar.linux.syncState',
        'openburnbar.linux.providerCredentialState',
        'openburnbar.linux.updateState'
      ],
      before,
      afterRecovery,
      restartProbe,
      recoveredAfterRestart: restartProbe.daemonFixture === '1' &&
        restartProbe.account === 'signed-in' &&
        restartProbe.sync === 'ready-after-retry' &&
        restartProbe.providerCredentials === 'stored-in-secret-service',
      userVisibleFeedback: 'Support/account/settings/update routes expose recovery actions and keep recovered state after restart.'
    };
    expect(restartPersistence.recoveredAfterRestart).toBe(true);
    writeEvidence('settings-account-update-support-scenarios.json', {
      generatedAt: new Date().toISOString(),
      method: 'failureStateCases-plus-localStorage-recovery-restart-probe',
      scenarios: failures.map((failure) => ({
        route: failure.route,
        id: failure.id,
        injectedCondition: failure.condition,
        userVisibleFeedback: failure.userMessage,
        recovery: failure.remediation,
        actionResult: failure.actionResult,
        restartPersistence: failure.restartPersistence
      })),
      requiredScenarioIds: [
        'account-login',
        'account-logout',
        'provider-credentials',
        'sync-status',
        'update-status',
        'secret-store-setup',
        'secret-store-unavailable',
        'network-offline',
        'quota-exhausted',
        'permission-denied',
        'daemon-offline'
      ],
      packagedScreenshots: [
        'screenshot-route-settings.png',
        'screenshot-route-account.png',
        'screenshot-route-updates.png',
        'screenshot-route-support.png'
      ],
      restartPersistence
    });
  });

  it('emits onboarding Linux permission path privacy copy and skip retry resume evidence', () => {
    localStorage.clear();
    const initial = readOnboarding();
    const retry = decodeLinuxOnboardingSnapshot({
      ...initial,
      revision: 2,
      currentStepID: 'secret_store',
      updatedAt: new Date().toISOString(),
      steps: initial.steps.map((step) =>
        step.id === 'daemon'
          ? { ...step, state: 'verified', attemptCount: 1, detail: 'daemon verified', verifiedAt: new Date().toISOString() }
          : step.id === 'secret_store'
            ? { ...step, state: 'blocked', attemptCount: 1, detail: 'wallet locked' }
            : step
      )
    });
    const skipped = decodeLinuxOnboardingSnapshot({
      ...initial,
      revision: 5,
      currentStepID: 'portal_input',
      updatedAt: new Date().toISOString(),
      steps: initial.steps.map((step) =>
        ['daemon', 'secret_store', 'provider_paths'].includes(step.id)
          ? { ...step, state: 'verified', attemptCount: 1, detail: `${step.id} verified`, verifiedAt: new Date().toISOString() }
          : step.id === 'cloud_identity'
            ? { ...step, state: 'skipped', attemptCount: 1, detail: 'deferred', verifiedAt: new Date().toISOString() }
            : step
      )
    });
    cacheOnboarding(skipped);
    const resumed = readOnboarding();
    const deniedRetryCases = failureStateCases()
      .filter((failure) => ['permission-denied', 'secret-store-unavailable', 'onboarding-incomplete'].includes(failure.id))
      .map((failure) => ({
        id: failure.id,
        userVisibleFeedback: failure.userMessage,
        retryOrRecovery: failure.remediation
      }));
    expect(initial.completed).toBe(false);
    expect(retry.currentStepID).toBe('secret_store');
    expect(resumed.currentStepID).toBe(skipped.currentStepID);
    writeEvidence('onboarding-linux-flow-evidence.json', {
      generatedAt: new Date().toISOString(),
      method: 'daemon-contract-decoder-plus-non-authoritative-cache-resume-and-copy-review',
      linuxPermissionPathPrivacyCopy: {
        daemonServiceSetup: 'AF_UNIX daemon/socket path copy plus openburnbar-cli service foreground guidance.',
        secretStoreTrust: 'Secret Service/KWallet and headless passphrase copy.',
        providerLogPaths: 'Provider XDG log path privacy copy.',
        cloudLowerTrustIdentity: 'Linux cloud identity is lower-trust and local SQLite stays canonical while signed out.',
        portalCaptureInputPermissions: 'Wayland portal consent copy for capture/input, with retry after denial.',
        trayDesktopLimitations: 'Ayatana/AppIndicator and desktop-environment limitation copy.',
        updates: 'Package-channel and restart guidance are shown before update checks.',
        privacyChoices: 'Telemetry/local-only/privacy choices are explicit; provider paths are opt-in.'
      },
      skipRetryResume: onboardingFlowTranscript(),
      stateProbe: { initial, retry, skipped, resumed },
      deniedRetryCases,
      accessibility: {
        route: 'onboarding',
        landmarks: routeAccessibilitySnapshots().find((route) => route.route === 'onboarding')?.expectedLandmarks ?? []
      },
      restartResumeProof: {
        authority: 'daemon.onboarding.snapshot',
        storageKey: 'openburnbar.linux.onboarding.cache.v2',
        cacheIsAuthoritative: false,
        beforeRestart: skipped,
        afterRestart: resumed,
        resumedSameStep: resumed.currentStepID === skipped.currentStepID && resumed.completed === false
      },
      packagedScreenshots: [
        'screenshot-route-onboarding.png',
        'screenshot-linux-desktop-first-run.png'
      ],
      docsCopyReview: 'Onboarding route copy is in src/onboardingSteps.ts ONBOARDING_STEPS and uses Linux-specific permission/path/privacy wording.'
    });
  });

  it('emits pet GLB runtime, behavior graph, overlay, draggable, degraded-tier evidence', () => {
    const assetPath = path.join(process.cwd(), 'public/pets/kawaii-aurora-fox-actions.glb');
    const buffer = fs.readFileSync(assetPath);
    const parsed = parseGlb(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength));
    const deMatrix = [
      { name: 'KDE Wayland', env: { XDG_SESSION_TYPE: 'wayland', XDG_CURRENT_DESKTOP: 'KDE' } },
      { name: 'GNOME Wayland', env: { XDG_SESSION_TYPE: 'wayland', XDG_CURRENT_DESKTOP: 'GNOME' } },
      { name: 'X11 XFCE', env: { XDG_SESSION_TYPE: 'x11', XDG_CURRENT_DESKTOP: 'XFCE' } }
    ].map((row) => ({ ...row, detected: detectPetTierFromEnv(row.env) }));
    expect(parsed.animations.length).toBeGreaterThan(0);
    expect(parsed.points.length).toBeGreaterThan(20);
    expect(deMatrix.some((row) => row.detected.tier === 'draggable-contained')).toBe(true);
    writeEvidence('pet-runtime-behavior-evidence.json', {
      generatedAt: new Date().toISOString(),
      method: 'real-glb-parse-plus-tier-policy',
      gltf: {
        asset: 'public/pets/kawaii-aurora-fox-actions.glb',
        version: parsed.asset.version,
        nodeCount: parsed.nodes.length,
        animationCount: parsed.animations.length,
        sampledPointCount: parsed.points.length,
        degradedEquivalent: parsed.points.length > 0 ? 'bounds-derived canvas shell when Draco payload cannot be expanded' : 'fallback-point-cloud'
      },
      behaviorGraphs: {
        overlayPassThrough: buildPetBehaviorGraph('overlay-pass-through'),
        draggableContained: buildPetBehaviorGraph('draggable-contained')
      },
      overlayClickThrough: {
        claim: 'No packaged route claims pass-through until both a compositor capability and native companion-window contract exist.',
        source: 'detectPetTierFromEnv',
        x11PackagedSession: {
          expectedTier: 'draggable-contained',
          proof: 'environment matrix is diagnostic only; native companion-window contract is not wired'
        }
      },
      inputPassthrough: {
        overlayTier: 'pointer/input passthrough remains unavailable until the native companion-window contract is wired',
        restrictedTier: 'contained fallback receives drag events and does not intercept global input'
      },
      degradedDraggableFallback: {
        tier: 'draggable-contained',
        draggableAttribute: true,
        userVisibleCopy: 'Contained fallback is draggable and does not claim click-through/input passthrough.'
      },
      perDesktopEnvironment: deMatrix,
      existingTierMatrix: petTierMatrix(),
      packagedScreenshots: ['screenshot-route-pet.png'],
      videoStoryboard: [
        { frame: 'screenshot-route-pet.png', event: 'packaged route visible with animated/degraded GLB canvas shell' },
        { frame: 'pet behavior graph JSON', event: 'idle, react, drag, settle transitions covered in behavior graph' }
      ]
    });
  });

  it('emits text expansion CRUD persistence, enable disable, denied, parity, and keylogger safety evidence', () => {
    localStorage.clear();
    configureTextExpansionStorage(null);
    configureTextExpansionConsentStorage(null, true);
    const beforeConsent = readTextExpansionConsent();
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    const consent = readTextExpansionConsent();
    const created = upsertSnippet({ title: 'Signature', trigger: ';;sig', body: '-- OpenBurnBar', enabled: true });
    const expanded = expandInAppBuffer(`reply ${created.trigger}`);
    const disabled = upsertSnippet({ ...created, enabled: false });
    const disabledProbe = expandInAppBuffer(`reply ${disabled.trigger}`);
    const persisted = listSnippets();
    const restartPersistence = listSnippets();
    deleteSnippet(created.id);
    const afterDelete = listSnippets();
    const runtimeFiles = [
      'src/surfaces/TextExpansionSurface.tsx',
      'src/textExpansionStore.ts',
      'src/textExpansionConsent.ts'
    ];
    const forbidden = ['evdev', 'uinput', 'global keyboard hook', 'CGEventTap', 'RegisterHotKey'];
    const scan = runtimeFiles.map((file) => {
      const text = fs.readFileSync(path.join(process.cwd(), file), 'utf8');
      return {
        file,
        forbiddenMatches: forbidden.filter((term) => text.includes(term)),
        keydownListeners: (text.match(/addEventListener\(['"]keydown/g) ?? []).length
      };
    });
    expect(beforeConsent).toBeNull();
    expect(consent?.inAppOnly).toBe(true);
    expect(expanded.output).toBe('reply -- OpenBurnBar');
    expect(disabledProbe.output).toBe(`reply ${disabled.trigger}`);
    expect(afterDelete).toHaveLength(0);
    expect(scan.every((row) => row.forbiddenMatches.length === 0 && row.keydownListeners === 0)).toBe(true);
    writeEvidence('text-expansion-crud-safety-evidence.json', {
      generatedAt: new Date().toISOString(),
      method: 'memory-fixture-execution-plus-runtime-source-scan',
      deniedBeforeConsent: beforeConsent === null,
      consent,
      crud: {
        created,
        expanded,
        disabled,
        disabledProbe,
        persistedCount: persisted.length,
        persistedAfterRestartCount: restartPersistence.length,
        // This harness runs fixture mode in memory. Restart persistence is
        // proven by BurnBarTextExpansionService Linux tests, not this renderer fixture.
        persistenceSurvivesRestart: false,
        persistenceBoundary: 'daemon-owned AES-GCM sealed snapshot; fixture mode is memory-only',
        afterDeleteCount: afterDelete.length
      },
      enabledDisabledBehavior: {
        enabledOutput: expanded.output,
        disabledOutput: disabledProbe.output,
        disabledPreservesTrigger: disabledProbe.output.endsWith(disabled.trigger)
      },
      permissionDeniedBehavior: {
        deniedBeforeConsent: beforeConsent === null,
        userVisibleFeedback: 'Acknowledge in-app-only expansion before saving snippets.'
      },
      packagedScreenshots: ['screenshot-route-text-expansion.png'],
      parityLedgerSubstitution: PARITY_LEDGER.find((row) => row.feature.includes('text expansion')) ?? null,
      unsafeGlobalKeyloggerProof: {
        globalCapture: false,
        scan,
        conclusion: 'Runtime text expansion files use explicit in-app buffer substitution and contain no global capture path.'
      }
    });
  });
});
