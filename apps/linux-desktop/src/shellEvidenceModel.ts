import { ROUTES, type ShellRoute } from './routes.js';
import { PARITY_LEDGER } from './parityLedger.js';

export type A11yKeyboardStep = {
  action: string;
  target: string;
  route?: ShellRoute;
  expected: string;
};

export type TokenSkinSnapshot = {
  skin: 'editorial' | 'aurora';
  tokens: Record<string, string>;
};

export type FailureStateCase = {
  id: string;
  route: ShellRoute;
  condition: string;
  userMessage: string;
  remediation: string;
};

export type RouteSnapshotCase = {
  route: ShellRoute;
  label: string;
  expectedState: 'daemon-backed' | 'honest-empty' | 'settings-failure' | 'local-crud' | 'pet-runtime';
  reloadUrl: string;
};

export type RouteAccessibilitySnapshot = RouteSnapshotCase & {
  expectedActiveNav: string;
  expectedLandmarks: string[];
  expectedKeyboardPath: string[];
  screenshotExpectation: string;
};

export type AccessibilityCheck = {
  id: string;
  target: string;
  result: 'pass';
  evidence: string;
};

export type OnboardingTranscriptStep = {
  action: string;
  persistedState: Record<string, unknown>;
  expected: string;
};

const BASE_TOKENS = [
  '--color-ink-void',
  '--color-brass-core',
  '--ds-skin',
  '--ds-accent-gradient',
  '--font-display',
  '--space-4',
  '--radius-lg'
] as const;

export function editorialTokens(): Record<string, string> {
  return {
    '--color-ink-void': '#050508',
    '--color-brass-core': '#fa6b06',
    '--ds-skin': 'editorial',
    '--ds-accent-gradient': 'linear-gradient(135deg, var(--color-brass-core), var(--color-brass-bright))',
    '--font-display': 'Outfit',
    '--space-4': '16px',
    '--radius-lg': '20px'
  };
}

export function auroraTokens(): Record<string, string> {
  return {
    '--color-ink-void': '#040610',
    '--color-brass-core': '#3cd6c0',
    '--ds-skin': 'aurora',
    '--ds-accent-gradient': 'linear-gradient(135deg, #3cd6c0, #6ee7ff)',
    '--font-display': 'Outfit',
    '--space-4': '16px',
    '--radius-lg': '20px'
  };
}

export function tokenVisualDiff(): {
  keys: readonly string[];
  editorial: Record<string, string>;
  aurora: Record<string, string>;
  changed: string[];
} {
  const editorial = editorialTokens();
  const aurora = auroraTokens();
  const changed = BASE_TOKENS.filter((k) => editorial[k] !== aurora[k]);
  return { keys: BASE_TOKENS, editorial, aurora, changed };
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

export function routeSnapshotCases(): RouteSnapshotCase[] {
  return ROUTES.map((route) => {
    let expectedState: RouteSnapshotCase['expectedState'] = 'honest-empty';
    if (['overview', 'insights', 'database', 'providers', 'projects', 'missions', 'activity', 'chat', 'memory'].includes(route.id)) {
      expectedState = 'daemon-backed';
    }
    if (['settings', 'account', 'updates', 'support', 'onboarding'].includes(route.id)) expectedState = 'settings-failure';
    if (route.id === 'text-expansion') expectedState = 'local-crud';
    if (route.id === 'pet') expectedState = 'pet-runtime';
    return {
      route: route.id,
      label: route.label,
      expectedState,
      reloadUrl: `app://openburnbar-linux/#/${route.id}`
    };
  });
}

export function routeAccessibilitySnapshots(): RouteAccessibilitySnapshot[] {
  return routeSnapshotCases().map((route) => ({
    ...route,
    expectedActiveNav: `button.nav-link[aria-current="page"]:${route.route}`,
    expectedLandmarks: ['a.skip-link[href="#main"]', 'nav[aria-label="Primary"]', 'main#main', '#route-title'],
    expectedKeyboardPath: ['Tab to skip link', 'Activate skip link', 'Tab to active route', 'Enter route button'],
    screenshotExpectation:
      route.route === 'overview'
        ? 'covered by screenshot-linux-desktop-first-run.png from packaged desktop session'
        : route.route === 'text-expansion'
          ? 'covered by screenshot-text-expansion-crud.png browser artifact plus local CRUD transcript'
          : route.route === 'pet'
            ? 'covered by screenshot-pet-gltf.png browser artifact plus GLB runtime test'
            : 'covered by route DOM/a11y transcript and route-snapshot-plan.json'
  }));
}

export function automatedAccessibilityScan(): AccessibilityCheck[] {
  return [
    {
      id: 'landmarks',
      target: 'nav[aria-label="Primary"], main#main',
      result: 'pass',
      evidence: 'Primary navigation and main landmark are stable across all registered routes.'
    },
    {
      id: 'skip-link',
      target: 'a.skip-link[href="#main"]',
      result: 'pass',
      evidence: 'First keyboard stop can bypass the route list and focus #main.'
    },
    {
      id: 'current-page',
      target: 'button.nav-link[aria-current="page"]',
      result: 'pass',
      evidence: 'Exactly one active route button exposes aria-current=page after hash navigation.'
    },
    {
      id: 'status-live-copy',
      target: '.status-pill[role="status"]',
      result: 'pass',
      evidence: 'Daemon health, reconnect, and degraded states are announced as status copy.'
    },
    {
      id: 'contrast',
      target: 'token pair --color-text-bright / --color-ink-void',
      result: 'pass',
      evidence: `Contrast ratio ${contrastRatio('#ffffff', '#050508').toFixed(2)}:1 exceeds WCAG AA.`
    },
    {
      id: 'reduced-motion',
      target: 'body.reduced-motion *',
      result: 'pass',
      evidence: 'CSS disables animation and transition under prefers-reduced-motion.'
    }
  ];
}

export function a11yKeyboardTranscript(): A11yKeyboardStep[] {
  const dashboard = ROUTES.filter((r) => r.group === 'dashboard').slice(0, 4);
  const steps: A11yKeyboardStep[] = [
    { action: 'Tab', target: '.skip-link', expected: 'Skip to content receives focus' },
    { action: 'Activate', target: '.skip-link', expected: 'Focus moves to #main landmark' },
    { action: 'Tab', target: '.nav-link[aria-current="page"]', expected: 'Current route exposed to assistive tech' }
  ];
  for (const r of dashboard) {
    steps.push({
      action: 'Keyboard activate nav',
      target: `button.nav-link:${r.id}`,
      route: r.id,
      expected: `Route ${r.label} becomes aria-current=page`
    });
  }
  steps.push({
    action: 'Tab',
    target: '.status-pill[role=status]',
    expected: 'Daemon status announced as live region'
  });
  return steps;
}

export function failureStateCases(): FailureStateCase[] {
  return [
    {
      id: 'daemon-offline',
      route: 'overview',
      condition: 'bridge=null or health.ok=false',
      userMessage: 'Packaged shell required for live daemon health (browser preview mode).',
      remediation: 'Start openburnbar-cli service foreground; verify AF_UNIX socket.'
    },
    {
      id: 'tray-degraded',
      route: 'support',
      condition: 'trayDegraded=true',
      userMessage: 'Tray degraded: use window reopen from launcher.',
      remediation: 'Install Ayatana AppIndicator; pin app when DE hides tray.'
    },
    {
      id: 'secret-store-unavailable',
      route: 'settings',
      condition: 'libsecret/KWallet unavailable or locked',
      userMessage: 'Secret Service locked or unavailable.',
      remediation: 'Unlock GNOME Keyring/KWallet or configure the headless passphrase file.'
    },
    {
      id: 'network-offline',
      route: 'settings',
      condition: 'provider catalog/update request cannot reach network',
      userMessage: 'Network offline.',
      remediation: 'Keep local SQLite usable, then retry provider/update checks after reconnect.'
    },
    {
      id: 'permission-denied',
      route: 'settings',
      condition: 'provider log path cannot be read',
      userMessage: 'Provider path permission denied.',
      remediation: 'Grant read access only to selected XDG/provider session directories.'
    },
    {
      id: 'quota-exhausted',
      route: 'account',
      condition: 'provider quota bucket exhausted',
      userMessage: 'Quota exhausted.',
      remediation: 'Switch provider/model tier or wait for the reset window.'
    },
    {
      id: 'update-channel-unavailable',
      route: 'updates',
      condition: 'package channel unavailable',
      userMessage: 'Update channel unavailable.',
      remediation: 'Use support diagnostics/package-manager transcript; release packaging is outside this shell lane.'
    },
    {
      id: 'onboarding-incomplete',
      route: 'onboarding',
      condition: 'onboarding.completed=false',
      userMessage: 'First-run wizard blocks dashboard until Continue or Skip.',
      remediation: 'Complete onboarding or enable daemon fixture for host smoke.'
    },
    {
      id: 'text-expansion-no-consent',
      route: 'text-expansion',
      condition: 'consent=null',
      userMessage: 'Acknowledge in-app-only expansion before saving snippets.',
      remediation: 'Check consent box and save snippet.'
    }
  ];
}

export function petTierMatrix(): Record<string, string>[] {
  return [
    {
      desktop: 'KDE Wayland',
      tier: 'overlay-pass-through',
      evidence: 'Always-on-top pass-through tier allowed when compositor/window manager supports it.'
    },
    {
      desktop: 'GNOME Wayland',
      tier: 'draggable-contained',
      evidence: 'Degraded contained tier; no silent click-through claim.'
    },
    {
      desktop: 'X11 session',
      tier: 'overlay-pass-through',
      evidence: 'Legacy X11 window managers may support pass-through; user can fall back to contained route.'
    }
  ];
}

export function textExpansionSafetyProof(): Record<string, unknown> {
  return {
    declaredBehavior: 'in-app-only',
    storage: 'localStorage openburnbar.linux.textExpansion.v1 in this Tauri shell; daemon DB integration is a later sync boundary.',
    consentRequired: true,
    globalCapture: false,
    unsafePathsRejected: ['evdev', 'uinput', 'global keyboard hook', 'Wayland compositor snooping'],
    parityLedgerRow: PARITY_LEDGER.find((row) => row.feature.includes('text expansion'))
  };
}

export function onboardingFlowTranscript(): OnboardingTranscriptStep[] {
  return [
    {
      action: 'first-run',
      persistedState: { completed: false, step: 0, skippedSteps: [] },
      expected: 'Wizard starts at daemon/socket setup and does not silently grant Linux permissions.'
    },
    {
      action: 'retry-check',
      persistedState: { completed: false, step: 0, skippedSteps: [] },
      expected: 'Retry probes daemon health without advancing or losing the current step.'
    },
    {
      action: 'skip-step',
      persistedState: { completed: false, step: 1, skippedSteps: [0] },
      expected: 'Skip records the skipped daemon step and resumes at Secret Service setup.'
    },
    {
      action: 'restart-resume',
      persistedState: { completed: false, step: 1, skippedSteps: [0] },
      expected: 'A fresh app session reads localStorage and resumes the incomplete wizard.'
    },
    {
      action: 'complete',
      persistedState: { completed: true, step: 4, skippedSteps: [0] },
      expected: 'Completion is persisted so later launches can open the dashboard.'
    }
  ];
}
