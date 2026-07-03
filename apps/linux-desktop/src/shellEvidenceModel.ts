import { ROUTES, type ShellRoute } from './routes.js';

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