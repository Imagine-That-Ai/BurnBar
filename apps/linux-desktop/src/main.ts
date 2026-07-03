import { applyReducedMotionClass } from './a11y.js';
import {
  inputPolicyReplay,
  linuxComputerUseAdapters,
  mediaCodecTrace,
  mobileProtocolReplayFrames,
  permissionStateRows,
  safetyInvariantSummary
} from './computerUseLinux.js';
import {
  fixtureDaemonHealth,
  isDaemonFixtureMode,
  routeFixture,
  setDaemonFixtureMode
} from './daemonFixture.js';
import { readOnboarding, writeOnboarding } from './onboardingStore.js';
import { buildPetBehaviorGraph } from './petBehaviorGraph.js';
import { detectPetTierFromEnv } from './petCompanion.js';
import { PARITY_LEDGER } from './parityLedger.js';
import { PROVIDER_GLYPHS } from './providerGlyphs.js';
import { markStart, listPerfSamples } from './perfMarks.js';
import { ROUTES, routeFromHash, type ShellRoute } from './routes.js';
import { displayLinuxConfigDir, displayLinuxSocketPath, displayLinuxSupportDir } from './shellPaths.js';
import { readTextExpansionConsent, writeTextExpansionConsent } from './textExpansionConsent.js';
import {
  deleteSnippet,
  expandInAppBuffer,
  listSnippets,
  upsertSnippet
} from './textExpansionStore.js';
import { loadShellBridge, type LinuxShellBridge } from './tauriBridge.js';
import type { DaemonHealth } from './daemonClient.js';

type ShellState = {
  route: ShellRoute;
  health: DaemonHealth | null;
  healthError: string | null;
  trayDegraded: boolean;
  skin: 'editorial' | 'aurora';
  bridge: LinuxShellBridge | null;
  fixtureMode: boolean;
  editingSnippetId: string | null;
};

const state: ShellState = {
  route: routeFromHash(location.hash),
  health: null,
  healthError: null,
  trayDegraded: false,
  skin: 'editorial',
  bridge: null,
  fixtureMode: false,
  editingSnippetId: null
};

const ONBOARDING_STEPS = [
  {
    title: 'Local daemon & socket',
    body: `OpenBurnBar talks to the Linux peer over AF_UNIX at ${displayLinuxSocketPath()}. Start the daemon with openburnbar-cli service foreground or your systemd user unit before using dashboard features.`
  },
  {
    title: 'Secret Service / SQLCipher',
    body: `Database keys live in libsecret/KWallet when available. Headless peers may require an explicit passphrase path documented in Settings. Config: ${displayLinuxConfigDir()}.`
  },
  {
    title: 'Provider log paths',
    body: 'Linux parsers read ~/.local/share/opencode, ~/.local/share/goose/sessions, ~/.codex, and other XDG paths. Confirm paths in Settings → Providers before expecting ingest.'
  },
  {
    title: 'Portal capture & input',
    body: 'Wayland screen capture and remote control require xdg-desktop-portal consent. Computer Use adapters are separate; this shell surfaces permission copy and Support diagnostics only.'
  },
  {
    title: 'Tray & desktop environment',
    body: 'Ayatana AppIndicator is used when present. Some DEs hide legacy tray icons — use Support → Reopen dashboard and keep the app pinned if the tray is unavailable.'
  }
];

const DASHBOARD_DATA_ROUTES = new Set<ShellRoute>([
  'overview',
  'insights',
  'database',
  'providers',
  'projects',
  'missions',
  'activity',
  'chat',
  'memory'
]);

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Record<string, string> = {},
  children: (Node | string)[] = []
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2).toLowerCase(), () => undefined);
    else node.setAttribute(k, v);
  }
  for (const child of children) {
    node.append(child instanceof Node ? child : document.createTextNode(child));
  }
  return node;
}

function setRoute(route: ShellRoute): void {
  const end = markStart('route.navigation', `packaged-ui-route:${route}`);
  state.route = route;
  location.hash = `#/${route}`;
  render();
  end();
}

function routeSurfaceMetric(route: ShellRoute): { name: string; source: string } | null {
  switch (route) {
    case 'chat':
      return { name: 'chat.firstToken.progress', source: 'packaged-chat-route-render-live-daemon-state' };
    case 'database':
      return { name: 'db.migration.open.query', source: 'packaged-database-route-render-live-daemon-state' };
    case 'activity':
      return { name: 'parser.incremental.run', source: 'packaged-activity-route-render-live-daemon-state' };
    case 'memory':
      return { name: 'memory.search', source: 'packaged-memory-route-render-live-daemon-state' };
    default:
      return null;
  }
}

function appendDaemonDataTable(wrap: HTMLElement, route: ShellRoute, label: string): void {
  const useFixture = state.fixtureMode || (state.health?.daemonVersion?.startsWith('fixture') ?? false);
  if (!useFixture && !state.health?.ok) {
    wrap.append(
      el('p', { class: 'muted', role: 'status' }, [
        'Daemon offline — honest empty state until the local peer is reachable.'
      ])
    );
    return;
  }
  const fx = routeFixture(route, label);
  const source = useFixture ? 'fixture transcript' : 'live health ok';
  wrap.append(el('p', { class: 'muted' }, [`Data source: ${source}`]));
  const table = el('table', { class: 'table fixture-table' });
  table.append(el('thead', {}, [el('tr', {}, [el('th', {}, ['ID']), el('th', {}, ['Title']), el('th', {}, ['Detail'])])]));
  const body = el('tbody');
  for (const row of fx.rows) {
    body.append(el('tr', {}, [el('td', {}, [row.id]), el('td', {}, [row.title]), el('td', {}, [row.detail])]));
  }
  table.append(body);
  wrap.append(table);
}

function computerUsePanel(wrap: HTMLElement): void {
  const states = permissionStateRows();
  const statusGrid = el('div', { class: 'cu-status-grid', 'aria-label': 'Computer Use permission states' });
  for (const row of states) {
    statusGrid.append(
      el('div', { class: `cu-status ${row.state}`, 'data-cu-state': row.id }, [
        el('strong', {}, [row.uiLabel]),
        el('span', {}, [row.evidence])
      ])
    );
  }
  wrap.append(statusGrid);

  const adapters = linuxComputerUseAdapters();
  const table = el('table', { class: 'table cu-adapter-table' });
  table.append(el('thead', {}, [
    el('tr', {}, [
      el('th', {}, ['Adapter']),
      el('th', {}, ['Target']),
      el('th', {}, ['Protocol']),
      el('th', {}, ['Gate'])
    ])
  ]));
  const body = el('tbody');
  for (const adapter of adapters) {
    body.append(
      el('tr', { 'data-adapter': adapter.id }, [
        el('td', {}, [adapter.id]),
        el('td', {}, [adapter.target]),
        el('td', {}, [adapter.protocol]),
        el('td', {}, [
          adapter.requiresConsent
            ? 'consent + approval'
            : adapter.requiresApproval
              ? 'approval'
              : 'local'
        ])
      ])
    );
  }
  table.append(body);
  wrap.append(table);

  const replay = inputPolicyReplay();
  const allowed = replay.filter((entry) => entry.decision.allowed).length;
  const denied = replay.length - allowed;
  const mobileFrames = mobileProtocolReplayFrames();
  const codecTrace = mediaCodecTrace();
  const invariants = safetyInvariantSummary();
  wrap.append(
    el('p', { class: 'muted' }, [
      `Policy replay: ${allowed} approved, ${denied} denied, ${mobileFrames.length} mobile frames, ${codecTrace.length} codec/backpressure rows.`
    ]),
    el('p', { class: 'muted' }, [
      invariants.noGlobalKeylogging && invariants.noSilentAutopilot
        ? 'Safety: no global keylogging, no silent autopilot.'
        : 'Safety invariant failure.'
    ])
  );
}

function textExpansionPanel(wrap: HTMLElement): void {
  const consent = readTextExpansionConsent();
  const consentRow = el('label', {}, [
    el('input', { type: 'checkbox', ...(consent?.inAppOnly ? { checked: 'true' } : {}) }),
    ' In-app expansion only (v1). No global key capture on Linux.'
  ]);
  const consentInput = consentRow.querySelector('input');
  consentInput?.addEventListener('change', () => {
    if (!consentInput.checked) return;
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    render();
  });
  if (!consent?.inAppOnly) {
    wrap.append(
      el('div', { class: 'banner degraded', role: 'alert' }, [
        'Acknowledge in-app-only expansion before saving snippets.'
      ]),
      consentRow
    );
    return;
  }
  wrap.append(consentRow);

  const form = el('form', { class: 'snippet-form' });
  const titleInput = el('input', { type: 'text', name: 'title', placeholder: 'Title', required: 'true' });
  const triggerInput = el('input', { type: 'text', name: 'trigger', placeholder: 'Trigger e.g. ;;sig', required: 'true' });
  const bodyInput = el('textarea', { name: 'body', rows: '3', placeholder: 'Expansion body' });
  const enabledInput = el('input', { type: 'checkbox', name: 'enabled', checked: 'true' });
  form.append(
    el('label', {}, ['Title', titleInput]),
    el('label', {}, ['Trigger', triggerInput]),
    el('label', {}, ['Body', bodyInput]),
    el('label', {}, [enabledInput, ' Enabled'])
  );

  const editing = state.editingSnippetId ? listSnippets().find((s) => s.id === state.editingSnippetId) : undefined;
  if (editing) {
    titleInput.value = editing.title;
    triggerInput.value = editing.trigger;
    bodyInput.value = editing.body;
    if (!editing.enabled) enabledInput.removeAttribute('checked');
  }

  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    upsertSnippet({
      id: editing?.id,
      title: titleInput.value,
      trigger: triggerInput.value,
      body: bodyInput.value,
      enabled: enabledInput.checked
    });
    state.editingSnippetId = null;
    render();
  });
  const saveBtn = el('button', { class: 'primary', type: 'submit' }, [editing ? 'Update snippet' : 'Add snippet']);
  form.append(saveBtn);
  wrap.append(form);

  const list = el('ul', { class: 'snippet-list' });
  for (const s of listSnippets()) {
    const li = el('li', {}, [
      el('strong', {}, [s.trigger]),
      ` — ${s.title}`,
      s.enabled ? '' : ' (disabled)'
    ]);
    const editBtn = el('button', { class: 'ghost', type: 'button' }, ['Edit']);
    editBtn.addEventListener('click', () => {
      state.editingSnippetId = s.id;
      render();
    });
    const delBtn = el('button', { class: 'ghost', type: 'button' }, ['Delete']);
    delBtn.addEventListener('click', () => {
      deleteSnippet(s.id);
      if (state.editingSnippetId === s.id) state.editingSnippetId = null;
      render();
    });
    li.append(editBtn, delBtn);
    list.append(li);
  }
  wrap.append(list);

  const probe = expandInAppBuffer(';;probe');
  wrap.append(el('p', { class: 'muted' }, [`Live buffer probe → ${probe.output}`]));

  const row = PARITY_LEDGER.find((r) => r.feature.includes('text expansion'));
  if (row?.substitution) wrap.append(el('p', { class: 'muted' }, [row.substitution]));
}

async function refreshHealth(): Promise<void> {
  const end = markStart('ipc.health.roundtrip', 'packaged-tauri-daemon-health-af-unix');
  if (state.fixtureMode) {
    state.health = fixtureDaemonHealth(displayLinuxSocketPath());
    state.healthError = null;
    end();
    render();
    return;
  }
  if (!state.bridge) {
    state.health = null;
    state.healthError = 'Packaged shell required for live daemon health (browser preview mode).';
    end();
    render();
    return;
  }
  try {
    state.health = await state.bridge.daemonHealth();
    state.healthError = state.health.ok ? null : state.health.error ?? 'Daemon reported not ready';
  } catch (e) {
    state.health = { ok: false };
    state.healthError = e instanceof Error ? e.message : 'Health probe failed';
  }
  end();
  render();
}

function navButton(route: ShellRoute, label: string): HTMLButtonElement {
  const btn = el('button', {
    class: 'nav-link',
    type: 'button',
    'aria-current': state.route === route ? 'page' : 'false'
  }, [label]);
  btn.addEventListener('click', () => setRoute(route));
  return btn;
}

function statusPill(): HTMLElement {
  const ok = state.health?.ok;
  const klass = ok ? 'status-pill ok' : state.healthError ? 'status-pill err' : 'status-pill warn';
  const label = ok
    ? `Daemon ${state.health?.daemonVersion ?? 'ready'}${state.fixtureMode ? ' (fixture)' : ''}`
    : state.healthError ?? 'Daemon status unknown';
  return el('div', { class: klass, role: 'status' }, [label]);
}

function routePanel(): HTMLElement {
  const meta = ROUTES.find((r) => r.id === state.route);
  const title = meta?.label ?? state.route;
  const desc = meta?.description ?? '';
  const wrap = el('section', { class: 'card', 'aria-labelledby': 'route-title' }, [
    el('h2', { id: 'route-title' }, [title]),
    el('p', { class: 'muted' }, [desc])
  ]);

  if (state.route === 'overview') {
    wrap.append(
      el('p', {}, [`Data dir: ${displayLinuxSupportDir()}`]),
      el('p', {}, [`Socket: ${displayLinuxSocketPath()}`]),
      el('div', { class: 'actions' }, [])
    );
    const reconnect = el('button', { class: 'primary', type: 'button' }, ['Reconnect']);
    reconnect.addEventListener('click', () => void refreshHealth());
    wrap.querySelector('.actions')?.append(reconnect);
    appendDaemonDataTable(wrap, 'overview', title);
  }

  if (state.route === 'settings' || state.route === 'account' || state.route === 'support') {
    const banner = el('div', { class: 'banner degraded', role: 'alert' }, [
      state.healthError
        ? `${state.healthError} Use openburnbar-cli health and check ${displayLinuxSocketPath()}.`
        : 'Connected to local peer.'
    ]);
    wrap.append(banner);
  }

  if (state.route === 'providers') {
    const glyphs = el('div', { class: 'provider-glyphs', 'aria-label': 'Provider glyphs' });
    for (const g of PROVIDER_GLYPHS) {
      glyphs.append(
        el('span', { class: 'glyph-chip' }, [
          el('span', { class: 'glyph-dot', style: `background:${g.accent}` }),
          g.label
        ])
      );
    }
    wrap.append(glyphs);
    appendDaemonDataTable(wrap, 'providers', title);
  }

  if (DASHBOARD_DATA_ROUTES.has(state.route) && state.route !== 'overview' && state.route !== 'providers') {
    const metric = routeSurfaceMetric(state.route);
    const end = metric ? markStart(metric.name, metric.source) : null;
    appendDaemonDataTable(wrap, state.route, title);
    end?.();
  }

  if (state.route === 'computer-use') {
    const end = markStart('media.control.stage', 'packaged-computer-use-route-media-control-surface');
    computerUsePanel(wrap);
    end();
  }

  if (state.route === 'onboarding') {
    const ob = readOnboarding();
    const step = ONBOARDING_STEPS[ob.step] ?? ONBOARDING_STEPS[0];
    wrap.append(el('h3', {}, [step.title]), el('p', {}, [step.body]));
    const actions = el('div', { class: 'actions' });
    const next = el('button', { class: 'primary', type: 'button' }, ['Continue']);
    next.addEventListener('click', () => {
      const n = Math.min(ob.step + 1, ONBOARDING_STEPS.length - 1);
      writeOnboarding({ step: n, completed: n === ONBOARDING_STEPS.length - 1 });
      render();
    });
    const skip = el('button', { class: 'ghost', type: 'button' }, ['Skip step']);
    skip.addEventListener('click', () => {
      writeOnboarding({ skippedSteps: [...ob.skippedSteps, ob.step] });
      render();
    });
    actions.append(next, skip);
    wrap.append(actions);
  }

  if (state.route === 'pet') {
    const tier = detectPetTierFromEnv({
      XDG_SESSION_TYPE: 'wayland',
      XDG_CURRENT_DESKTOP: 'GNOME'
    });
    const graph = buildPetBehaviorGraph(tier.tier);
    wrap.append(
      el('div', { class: 'pet-stage', role: 'img', 'aria-label': 'Pet companion preview' }, ['🐾']),
      el('p', {}, [`Tier: ${tier.tier}`]),
      el('p', { class: 'muted' }, [tier.message]),
      el('p', {}, [`glTF: ${graph.gltfAsset}`]),
      el('pre', { class: 'pet-graph' }, [JSON.stringify(graph.nodes, null, 2)])
    );
  }

  if (state.route === 'text-expansion') {
    textExpansionPanel(wrap);
  }

  if (state.route === 'support') {
    const table = el('table', { class: 'table' });
    table.append(el('thead', {}, [el('tr', {}, [el('th', {}, ['Perf sample']), el('th', {}, ['ms'])])]));
    const body = el('tbody');
    for (const s of listPerfSamples()) {
      body.append(el('tr', {}, [el('td', {}, [s.name]), el('td', {}, [s.ms.toFixed(1)])]));
    }
    table.append(body);
    wrap.append(table);
    if (state.trayDegraded) {
      wrap.append(el('p', { class: 'muted' }, ['Tray degraded: use window reopen from launcher.']));
    }
    const fixtureBtn = el('button', { class: 'ghost', type: 'button' }, [
      state.fixtureMode ? 'Disable daemon fixture' : 'Enable daemon fixture (host smoke)'
    ]);
    fixtureBtn.addEventListener('click', () => {
      state.fixtureMode = !state.fixtureMode;
      setDaemonFixtureMode(state.fixtureMode);
      void refreshHealth();
    });
    wrap.append(el('div', { class: 'actions' }, [fixtureBtn]));
  }

  if (
    !DASHBOARD_DATA_ROUTES.has(state.route) &&
    !['settings', 'account', 'support', 'onboarding', 'pet', 'text-expansion', 'updates', 'computer-use'].includes(state.route)
  ) {
    wrap.append(
      el('p', { class: 'muted' }, [
        state.health?.ok
          ? 'Route is wired; load live data from the daemon-backed lanes (W03/W04/W05).'
          : 'Daemon offline — showing honest empty state until the local peer is reachable.'
      ])
    );
  }

  return wrap;
}

function render(): void {
  const root = document.getElementById('root');
  if (!root) return;
  root.replaceChildren();
  document.documentElement.dataset.skin = state.skin;
  document.documentElement.style.setProperty('--ds-skin', state.skin);

  const skip = el('a', { class: 'skip-link', href: '#main' }, ['Skip to content']);
  const brand = el('div', { class: 'brand' }, ['Open', el('span', {}, ['BurnBar']), ' Linux']);
  const nav = el('nav', { class: 'shell-nav', 'aria-label': 'Primary' }, [brand, statusPill()]);
  nav.append(el('div', { class: 'nav-group-title' }, ['Dashboard']));
  for (const r of ROUTES.filter((x) => x.group === 'dashboard')) nav.append(navButton(r.id, r.label));
  nav.append(el('div', { class: 'nav-group-title' }, ['System']));
  for (const r of ROUTES.filter((x) => x.group === 'system')) nav.append(navButton(r.id, r.label));

  const skinToggle = el('button', { class: 'ghost', type: 'button' }, [`Skin: ${state.skin}`]);
  skinToggle.addEventListener('click', () => {
    state.skin = state.skin === 'editorial' ? 'aurora' : 'editorial';
    render();
  });
  nav.append(skinToggle);

  const main = el('main', { class: 'shell-main', id: 'main', tabindex: '-1' }, [routePanel()]);
  root.append(el('div', { class: 'shell' }, [skip, nav, main]));
}

async function boot(): Promise<void> {
  const end = markStart('app.start', 'packaged-tauri-boot-to-first-render');
  applyReducedMotionClass();
  state.fixtureMode = isDaemonFixtureMode();
  state.bridge = await loadShellBridge();
  if (state.bridge) state.trayDegraded = await state.bridge.trayDegraded();
  const ob = readOnboarding();
  if (!ob.completed && !location.hash) setRoute('onboarding');
  window.addEventListener('hashchange', () => {
    state.route = routeFromHash(location.hash);
    render();
  });
  window.addEventListener('keydown', (event) => {
    if (!event.ctrlKey || !event.shiftKey) return;
    const index = ROUTES.findIndex((route) => route.id === state.route);
    if (event.key === 'Home') {
      event.preventDefault();
      setRoute(ROUTES[0].id);
    }
    if (event.key === 'ArrowRight') {
      event.preventDefault();
      setRoute(ROUTES[(index + 1 + ROUTES.length) % ROUTES.length].id);
    }
    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      setRoute(ROUTES[(index - 1 + ROUTES.length) % ROUTES.length].id);
    }
  });
  await refreshHealth();
  end();
  render();
}

void boot();
