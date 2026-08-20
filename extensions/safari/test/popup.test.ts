import { renderPopup } from '../src/popup/render';
import { createInitialPopupState, reducePopupState } from '../src/popup/state';
import { buildPopupViewModel } from '../src/popup/viewModel';
import type { PopupSnapshot } from '../src/shared/messages';
import { buildSafariPerformanceDiagnostics } from '../src/shared/performance';
import { requireElement, requireValue } from './helpers/assertions';

afterEach(() => {
  document.body.replaceChildren();
});

function snapshot(overrides: Partial<PopupSnapshot> = {}): PopupSnapshot {
  return {
    stateVersion: 1,
    bridge: {
      connection: 'connected',
      daemonVersion: '1.0.34',
      gatewayReady: true,
      killSwitchEnabled: false,
      membership: 'pro',
      activeRunId: 'run-1',
      agents: [
        {
          id: 'vision-model',
          displayName: 'Vision Model',
          providerName: 'Cloud Provider',
          kind: 'model',
          installed: true,
          cloud: true,
          supportsVision: true
        },
        {
          id: 'text-model',
          displayName: 'Text Model',
          providerName: 'Cloud Provider',
          kind: 'model',
          installed: true,
          cloud: true,
          supportsVision: false
        },
        {
          id: 'codex',
          displayName: 'Codex',
          providerName: 'Installed agents',
          kind: 'cli',
          installed: true,
          cloud: false,
          supportsVision: false
        }
      ]
    },
    mode: 'ask',
    selectedAgentId: 'vision-model',
    page: {
      tabId: 1,
      windowId: 10,
      url: 'https://example.com/checkout',
      title: 'Example checkout',
      navigationEpoch: 2,
      isActive: true,
      isTopFrame: true,
      capturedAt: '2026-08-10T12:00:00Z',
      sensitive: true,
      permission: 'granted'
    },
    trust: {
      globalKillSwitch: false,
      onlyCurrentTab: true,
      siteAllowed: true,
      sensitiveSiteOverride: false,
      cloudScreenshotAcknowledged: true
    },
    learning: {
      eligible: true,
      optedIn: true,
      consentSeen: true,
      items: [
        {
          id: 'memory-1',
          version: 1,
          title: 'Prefers concise summaries',
          kind: 'memory',
          status: 'accepted',
          summary: 'Use a short executive summary first.',
          createdAt: '2026-08-10T12:00:00Z'
        },
        {
          id: 'skill-1',
          version: 3,
          title: 'Extract store prices',
          kind: 'skill',
          status: 'proposed',
          summary: 'A portable workflow proposal.',
          createdAt: '2026-08-10T12:00:00Z'
        }
      ]
    },
    transcript: [
      {
        id: 'message-1',
        role: 'user',
        text: 'What color is the button?',
        createdAt: '2026-08-10T12:00:00Z'
      },
      {
        id: 'message-2',
        role: 'assistant',
        text: 'The primary button is orange.',
        createdAt: '2026-08-10T12:00:01Z',
        streaming: true
      }
    ],
    approvals: [
      {
        id: 'approval-1',
        runId: 'run-1',
        title: 'Click “Buy”',
        summary: 'Agent wants to click the checkout button.',
        url: 'https://example.com/checkout',
        risk: 'sensitive',
        requestedAt: '2026-08-10T12:00:02Z'
      }
    ],
    activity: [
      {
        id: 'activity-1',
        runId: 'run-1',
        text: 'Page context verified.',
        tone: 'success',
        createdAt: '2026-08-10T12:00:02Z'
      }
    ],
    performance: buildSafariPerformanceDiagnostics(
      {
        schemaVersion: 1,
        retentionLimit: 240,
        totalRecorded: 3,
        droppedCount: 0,
        nextSequence: 4,
        samples: [
          {
            sequence: 1,
            metric: 'popup_bootstrap',
            durationMs: 38,
            outcome: 'success',
            recordedAt: '2026-08-12T12:00:00Z'
          },
          {
            sequence: 2,
            metric: 'ask_first_token',
            durationMs: 410,
            outcome: 'success',
            recordedAt: '2026-08-12T12:00:01Z',
            context: { route: 'cloud' }
          },
          {
            sequence: 3,
            metric: 'ask_first_token',
            durationMs: 520,
            outcome: 'aborted',
            recordedAt: '2026-08-12T12:00:02Z',
            context: { route: 'cloud' }
          }
        ]
      },
      'ready'
    ),
    running: true,
    busy: false,
    ...overrides
  };
}

function snapshotPage(): NonNullable<PopupSnapshot['page']> {
  return requireValue(snapshot().page, 'popup page snapshot');
}

describe('popup state and view model', () => {
  it('reduces local draft, filter, submission, initialization, and snapshot state', () => {
    const initial = createInitialPopupState();
    expect(initial.initialized).toBe(false);
    const withDraft = reducePopupState(initial, { type: 'draft', value: 'Hello' });
    expect(withDraft.draft).toBe('Hello');
    const withCorrection = reducePopupState(withDraft, {
      type: 'correctionDraft',
      value: 'Prefer annual totals.'
    });
    expect(withCorrection.correctionDraft).toBe('Prefer annual totals.');
    const withNotice = reducePopupState(withCorrection, {
      type: 'diagnosticsNotice',
      notice: {
        tone: 'success',
        text: 'Copied.'
      }
    });
    expect(withNotice.diagnosticsNotice).toEqual({ tone: 'success', text: 'Copied.' });
    const withoutNotice = reducePopupState(withNotice, {
      type: 'diagnosticsNotice'
    });
    expect(withoutNotice.diagnosticsNotice).toBeUndefined();
    const armed = reducePopupState(withoutNotice, { type: 'diagnosticsClearArmed', value: true });
    expect(armed.diagnosticsClearArmed).toBe(true);
    const filtered = reducePopupState(armed, { type: 'agentFilter', value: 'vision' });
    expect(filtered.agentFilter).toBe('vision');
    const submitting = reducePopupState(filtered, { type: 'submitting', value: true });
    expect(submitting.submitting).toBe(true);
    const initialized = reducePopupState(submitting, { type: 'initialized' });
    expect(initialized.initialized).toBe(true);
    const withSnapshot = reducePopupState(initialized, { type: 'snapshot', snapshot: snapshot() });
    expect(withSnapshot.snapshot?.bridge.connection).toBe('connected');
    expect(withSnapshot.submitting).toBe(true);
  });

  it('groups/filter agents and explains safety-disabled states', () => {
    const state = reducePopupState(
      {
        ...createInitialPopupState(),
        draft: 'Question',
        correctionDraft: 'Prefer annual totals.',
        agentFilter: 'vision'
      },
      { type: 'snapshot', snapshot: snapshot() }
    );
    const model = buildPopupViewModel(state);
    expect(model.connectionLabel).toBe('Connected');
    expect(model.agentGroups.flatMap((group) => group.agents).map((agent) => agent.id)).toEqual(['vision-model']);
    expect(model.agentFilter).toBe('vision');
    expect(model.primaryDisabled).toBe(false);
    expect(model.showCloudDisclosure).toBe(true);
    expect(model.pageSensitive).toBe(true);
    expect(model.correctionByteCount).toBe(new TextEncoder().encode('Prefer annual totals.').byteLength);
    expect(model.correctionSubmitDisabled).toBe(false);

    const denied = buildPopupViewModel({
      ...state,
      snapshot: snapshot({
        trust: {
          ...snapshot().trust,
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      })
    });
    expect(denied.primaryDisabledReason).toMatch(/Allow this website/u);

    const agentic = buildPopupViewModel({
      ...state,
      snapshot: snapshot({ mode: 'agentic' })
    });
    expect(agentic.primaryDisabledReason).toMatch(/sensitive site/u);

    const handoff = buildPopupViewModel({
      ...state,
      agentFilter: '',
      snapshot: snapshot({ mode: 'handoff', selectedAgentId: 'codex' })
    });
    expect(handoff.selectedAgent?.kind).toBe('cli');
    expect(handoff.primaryLabel).toBe('Prepare hand-off');

    const incompatibleHandoff = buildPopupViewModel({
      ...state,
      agentFilter: '',
      snapshot: snapshot({ mode: 'handoff', selectedAgentId: 'vision-model' })
    });
    expect(incompatibleHandoff.selectedAgent).toBeUndefined();
    expect(incompatibleHandoff.primaryDisabledReason).toMatch(/installed agent/u);

    const busy = buildPopupViewModel({
      ...state,
      submitting: false,
      snapshot: snapshot({ busy: true, running: false })
    });
    expect(busy.primaryDisabled).toBe(true);
    expect(busy.primaryDisabledReason).toMatch(/already handling/u);
    expect(busy.stopEnabled).toBe(true);

    const idle = buildPopupViewModel({
      ...state,
      snapshot: snapshot({ busy: false, running: false })
    });
    expect(idle.stopEnabled).toBe(false);
  });

  it('explains every connection, permission, model, trust, and page fallback state', () => {
    const localState = {
      ...createInitialPopupState(),
      initialized: true,
      draft: 'Continue'
    };
    const view = (value: PopupSnapshot) => buildPopupViewModel({ ...localState, snapshot: value });

    const withoutPage = snapshot();
    delete withoutPage.page;
    expect(view(withoutPage).primaryDisabledReason).toMatch(/regular webpage/u);

    expect(
      view(
        snapshot({
          page: { ...snapshotPage(), permission: 'unsupported' }
        })
      ).primaryDisabledReason
    ).toMatch(/does not allow extensions/u);

    expect(
      view(
        snapshot({
          trust: { ...snapshot().trust, globalKillSwitch: true }
        })
      ).primaryDisabledReason
    ).toBeUndefined();

    expect(
      view(
        snapshot({
          bridge: { ...snapshot().bridge, killSwitchEnabled: true }
        })
      ).primaryDisabledReason
    ).toBeUndefined();

    expect(
      view(
        snapshot({
          mode: 'agentic',
          page: { ...snapshotPage(), sensitive: false },
          trust: { ...snapshot().trust, globalKillSwitch: true }
        })
      ).primaryDisabledReason
    ).toMatch(/Computer Use kill switch/u);

    expect(view(snapshot({ selectedAgentId: 'missing' })).primaryDisabledReason).toMatch(/compatible model/u);
    expect(view(snapshot({ mode: 'handoff', selectedAgentId: 'missing' })).primaryDisabledReason).toMatch(
      /installed agent/u
    );

    expect(
      view(
        snapshot({
          bridge: { ...snapshot().bridge, gatewayReady: false }
        })
      ).primaryDisabledReason
    ).toMatch(/model gateway/u);

    expect(
      view(
        snapshot({
          page: { ...snapshotPage(), sensitive: false },
          trust: { ...snapshot().trust, cloudScreenshotAcknowledged: false }
        })
      ).primaryDisabledReason
    ).toMatch(/cloud screenshot/u);

    const degraded = view(
      snapshot({
        bridge: { ...snapshot().bridge, connection: 'degraded' },
        page: { ...snapshotPage(), url: 'not a valid URL', title: '', permission: 'prompt' }
      })
    );
    expect(degraded.connectionLabel).toBe('Limited');
    expect(degraded.connectionTone).toBe('warning');
    expect(degraded.pageLabel).toBe('No active page');
    expect(degraded.pageDetail).toBe('not a valid URL');
    expect(degraded.permissionLabel).toBe('Website access available on request');

    expect(
      view(
        snapshot({
          page: { ...snapshotPage(), permission: 'denied' }
        })
      ).permissionLabel
    ).toBe('Website access denied');
    expect(
      view(
        snapshot({
          page: { ...snapshotPage(), permission: 'denied' }
        })
      ).primaryDisabledReason
    ).toMatch(/Grant Safari website access/u);
  });
});

describe('popup rendering', () => {
  it('renders one first-use permission sheet that explains and completes the cloud setup sequence', () => {
    const root = document.createElement('div');
    renderPopup(
      root,
      buildPopupViewModel({
        ...createInitialPopupState(),
        initialized: true,
        draft: 'Summarize this page',
        snapshot: snapshot({
          page: { ...snapshotPage(), permission: 'prompt' },
          trust: {
            ...snapshot().trust,
            siteAllowed: false,
            cloudScreenshotAcknowledged: false
          }
        })
      })
    );

    const sheet = root.querySelector<HTMLElement>('.permission-sheet[role="dialog"]');
    expect(sheet).not.toBeNull();
    expect(sheet?.getAttribute('aria-modal')).toBe('true');
    expect(sheet?.textContent).toMatch(/Safari.*access/is);
    expect(sheet?.textContent).toMatch(/allow.*website/is);
    expect(sheet?.textContent).toMatch(/cloud.*screenshot/is);
    expect(sheet?.querySelectorAll('button')).toHaveLength(1);
    expect(sheet?.querySelector('[data-action="complete-permission-setup"]')).not.toBeNull();
    expect(
      sheet?.querySelector('[data-action="complete-permission-setup"]')?.getAttribute('aria-label') ??
        sheet?.querySelector('[data-action="complete-permission-setup"]')?.textContent
    ).toMatch(/allow|continue|set up/iu);
    expect(root.querySelector<HTMLButtonElement>('.composer-submit')?.disabled).toBe(true);
  });

  it('keeps the permission sheet until Safari access, durable origin trust, and cloud disclosure are all ready', () => {
    const root = document.createElement('div');
    const local = {
      ...createInitialPopupState(),
      initialized: true,
      draft: 'Summarize this page'
    };
    const renderBlocked = (value: PopupSnapshot): HTMLElement | null => {
      renderPopup(root, buildPopupViewModel({ ...local, snapshot: value }));
      return root.querySelector('.permission-sheet[role="dialog"]');
    };

    expect(
      renderBlocked(
        snapshot({
          page: { ...snapshotPage(), permission: 'prompt' },
          trust: { ...snapshot().trust, siteAllowed: false, cloudScreenshotAcknowledged: false }
        })
      )
    ).not.toBeNull();
    expect(
      renderBlocked(
        snapshot({
          trust: { ...snapshot().trust, siteAllowed: false, cloudScreenshotAcknowledged: false }
        })
      )
    ).not.toBeNull();
    expect(
      renderBlocked(
        snapshot({
          trust: { ...snapshot().trust, siteAllowed: true, cloudScreenshotAcknowledged: false }
        })
      )
    ).not.toBeNull();

    renderPopup(
      root,
      buildPopupViewModel({
        ...local,
        snapshot: snapshot({
          trust: { ...snapshot().trust, siteAllowed: true, cloudScreenshotAcknowledged: true }
        })
      })
    );
    expect(root.querySelector('.permission-sheet[role="dialog"]')).toBeNull();
    expect(root.querySelector<HTMLButtonElement>('.composer-submit')?.disabled).toBe(false);

    renderPopup(
      root,
      buildPopupViewModel({
        ...local,
        snapshot: snapshot({
          trust: { ...snapshot().trust, siteAllowed: true, cloudScreenshotAcknowledged: true }
        })
      })
    );
    expect(root.querySelector('.permission-sheet[role="dialog"]')).toBeNull();
  });

  it('does not request cloud screenshot disclosure for a local model', () => {
    const root = document.createElement('div');
    renderPopup(
      root,
      buildPopupViewModel({
        ...createInitialPopupState(),
        initialized: true,
        draft: 'Summarize this page locally',
        snapshot: snapshot({
          selectedAgentId: 'codex',
          mode: 'handoff',
          page: { ...snapshotPage(), sensitive: false, permission: 'granted' },
          trust: {
            ...snapshot().trust,
            siteAllowed: true,
            cloudScreenshotAcknowledged: false
          }
        })
      })
    );

    expect(root.querySelector('.permission-sheet[role="dialog"]')).toBeNull();
    expect(root.textContent).not.toMatch(/acknowledge.*cloud screenshot/iu);
    expect(root.querySelector<HTMLButtonElement>('.composer-submit')?.disabled).toBe(false);
  });

  it('keeps permission failures actionable without exposing a second setup flow', () => {
    const root = document.createElement('div');
    renderPopup(
      root,
      buildPopupViewModel({
        ...createInitialPopupState(),
        initialized: true,
        draft: 'Summarize this page',
        snapshot: snapshot({
          page: { ...snapshotPage(), permission: 'denied' },
          trust: {
            ...snapshot().trust,
            siteAllowed: false,
            cloudScreenshotAcknowledged: false
          },
          lastError: {
            code: 'permission_denied',
            message: 'Safari did not grant website access. Review the Safari prompt and try again.',
            retryable: true
          }
        })
      })
    );

    const sheet = root.querySelector<HTMLElement>('.permission-sheet[role="dialog"]');
    expect(sheet).not.toBeNull();
    expect(sheet?.textContent).toMatch(/Safari.*(denied|access)/isu);
    expect(sheet?.querySelectorAll('[data-action="complete-permission-setup"]')).toHaveLength(1);
    expect(root.querySelector('.error-banner')?.getAttribute('role')).toBe('alert');
    expect(root.querySelector('.error-banner')?.textContent).toContain(
      'Safari did not grant website access. Review the Safari prompt and try again.'
    );
    expect(root.querySelector('[data-action="refresh"]')).not.toBeNull();
  });

  it('renders the complete accessible operator cockpit without injecting message markup', () => {
    const root = document.createElement('div');
    document.body.append(root);
    const local = {
      ...createInitialPopupState(),
      initialized: true,
      draft: 'Find the least expensive option',
      correctionDraft: 'Always compare annual totals before monthly prices.',
      snapshot: snapshot({
        transcript: [
          ...snapshot().transcript,
          {
            id: 'unsafe',
            role: 'assistant' as const,
            text: '<img src=x onerror=alert(1)>',
            createdAt: '2026-08-10T12:00:03Z'
          }
        ],
        lastError: {
          code: 'demo',
          message: 'A recoverable test error.',
          retryable: true
        }
      })
    };
    renderPopup(root, buildPopupViewModel(local));

    expect(root.getAttribute('aria-busy')).toBe('false');
    expect(root.querySelector('[role="group"][aria-label="OpenBurnBar mode"]')?.getAttribute('aria-describedby')).toBe(
      'mode-description'
    );
    expect(root.querySelector('[role="group"][aria-label="OpenBurnBar mode"]')?.id).toBe('mode-popover');
    expect(root.querySelector('[data-input="mode-range"]')?.getAttribute('aria-describedby')).toBe('mode-description');
    expect(root.querySelector('[data-input="mode-range"]')?.getAttribute('aria-valuetext')).toBe('Ask');
    expect(root.querySelector('.mode-fire')?.tagName).toBe('CANVAS');
    expect(root.querySelector('.mode-knob')?.tagName).toBe('CANVAS');
    expect(root.querySelector('.mode-knob')?.getAttribute('aria-hidden')).toBe('true');
    expect(root.querySelector<HTMLElement>('.mode-track')?.style.getPropertyValue('--mode-fraction')).toBe('0');
    expect(root.querySelector<HTMLImageElement>('.mode-knob-fallback')?.src).toContain('icons/app-logo.svg');
    expect(root.querySelector('.mode-knob-fallback')?.getAttribute('aria-hidden')).toBe('true');
    expect(root.querySelectorAll('.mode-tick[aria-hidden="true"]')).toHaveLength(4);
    expect(root.querySelectorAll('.mode-button')).toHaveLength(4);
    expect(root.querySelectorAll('.mode-button[aria-pressed="true"]')).toHaveLength(1);
    expect(root.querySelector('.mode-button.is-selected')?.getAttribute('aria-pressed')).toBe('true');
    expect(root.querySelector('[role="tablist"], [role="tab"]')).toBeNull();
    expect(root.querySelector('.connection')?.textContent).toContain('Connected');
    expect(root.querySelector('.stop-button')?.hasAttribute('disabled')).toBe(false);
    expect(root.querySelector('.stop-button')?.getAttribute('aria-keyshortcuts')).toBe('Control+Alt+Meta+.');
    expect(root.querySelector('.approval-card')?.textContent).toContain('Allow once');
    expect(root.querySelector<HTMLTextAreaElement>('.composer-input')?.value).toBe('Find the least expensive option');
    expect(root.querySelector('.popup-tools')).toBeNull();
    expect(root.querySelector('.trust-drawer')).toBeNull();
    expect(root.querySelector('.learning-drawer')).toBeNull();
    expect(root.querySelector('.performance-drawer')).toBeNull();
    expect(root.querySelector('[data-action="toggle-tools"]')?.getAttribute('aria-expanded')).toBe('false');
    expect(root.querySelector('[data-action="toggle-popup-shape"]')?.getAttribute('aria-pressed')).toBe('true');
    expect(root.querySelector('.content-scroll .activity-strip')).toBeNull();
    expect(root.querySelector('.content-scroll .agent-drawer')).toBeNull();
    expect(root.querySelector('.model-picker-trigger')?.textContent).toContain('Vision Model');
    expect(root.querySelector('.model-picker-trigger')?.getAttribute('aria-label')).toContain('Cloud Provider');
    expect(root.querySelector('.model-picker-trigger .provider-mark--fallback')?.textContent).toBe('C');
    expect(root.querySelector('.mode-trigger .icon')?.getAttribute('aria-hidden')).toBe('true');
    expect(root.querySelector('.mode-trigger')?.getAttribute('aria-label')).toBe('Thinking level: Ask');
    expect(root.querySelector('[data-action="toggle-tools"]')?.hasAttribute('aria-controls')).toBe(false);
    expect(root.querySelector('.logo')?.getAttribute('alt')).toBe('');
    expect(root.querySelector('.composer-input')?.getAttribute('aria-keyshortcuts')).toBe('Meta+Enter');
    expect(root.querySelector('.composer-submit')?.getAttribute('aria-keyshortcuts')).toBe('Meta+Enter');
    expect(root.querySelector<HTMLButtonElement>('.mode-trigger')?.getAttribute('aria-controls')).toBe('mode-popover');
    expect(root.querySelector<HTMLButtonElement>('.mode-trigger')?.getAttribute('aria-expanded')).toBe('false');
    expect(root.querySelector('.composer-submit .icon')?.getAttribute('aria-hidden')).toBe('true');
    expect(root.querySelector('.error-banner')?.getAttribute('role')).toBe('alert');
    expect(root.querySelector('img[src="x"]')).toBeNull();
    expect(root.textContent).toContain('<img src=x onerror=alert(1)>');
    expect(root.querySelector('[data-action="approval:approval-1:allow_session"]')).not.toBeNull();
    expect(
      root.querySelector('[data-action="approval:approval-1:allow_session"]')?.getAttribute('aria-label')
    ).toContain('Click “Buy”');

    root.dataset.toolsOpen = 'true';
    renderPopup(root, buildPopupViewModel(local));
    expect(root.querySelector('.popup-tools')?.getAttribute('aria-label')).toBe('OpenBurnBar controls');
    expect(root.querySelector('[data-action="toggle-tools"]')?.getAttribute('aria-controls')).toBe('popup-tools');
    expect(root.querySelector('.trust-drawer')?.textContent).toContain('Screenshots stay on this Mac');
    expect(root.querySelector('.learning-drawer')?.textContent).toContain('Extract store prices');
    expect(root.querySelector('.performance-drawer')?.textContent).toContain('Ask first token');
    expect(root.querySelector('.performance-drawer')?.textContent).toContain('Local timing only');
    expect(root.querySelector('[data-action="toggle-tools"]')?.getAttribute('aria-expanded')).toBe('true');
    expect(root.querySelector('.agent-select')).toBeNull();
    expect(root.querySelector('.agent-picker-options[role="listbox"]')).not.toBeNull();
    expect(root.querySelector('.agent-picker-options .model-picker-option')?.textContent).toContain('Vision Model');
    expect(root.querySelector('[data-action="diagnostics-copy"]')?.getAttribute('aria-label')).toContain(
      'privacy-safe'
    );
    expect(root.querySelector('[data-action="diagnostics-download"]')?.getAttribute('aria-label')).toContain(
      'privacy-safe'
    );
    expect(root.querySelector('[data-action="diagnostics-clear"]')?.getAttribute('aria-label')).toContain(
      'retained local'
    );
    expect(root.querySelector('.learning-correction')?.textContent).toContain('Explicit only');
    expect(root.querySelector('.learning-correction-note')?.textContent).toContain('does not infer a correction');
    expect(root.querySelector<HTMLTextAreaElement>('[data-input="correction-draft"]')?.value).toBe(
      'Always compare annual totals before monthly prices.'
    );
    expect(root.querySelector('[data-input="correction-draft"]')?.getAttribute('aria-describedby')).toContain(
      'learning-correction-note'
    );
    expect(root.querySelector<HTMLButtonElement>('.learning-correction-submit')?.disabled).toBe(false);
    expect(root.querySelector('[data-action="learning:skill-1:approve"]')).not.toBeNull();
    expect(root.querySelector('[data-action="learning:skill-1:approve"]')?.getAttribute('aria-label')).toContain(
      'Extract store prices'
    );

    const interactiveControls = [...root.querySelectorAll<HTMLElement>('button, input, select, textarea, summary')];
    const focusKeys = interactiveControls.map((control) => control.dataset.focusKey);
    expect(focusKeys.every(Boolean)).toBe(true);
    expect(new Set(focusKeys).size).toBe(interactiveControls.length);
  });

  it('preserves drawer, scroll, search focus, and selection state across polling renders', () => {
    const root = document.createElement('div');
    document.body.append(root);
    const local = {
      ...createInitialPopupState(),
      initialized: true,
      agentFilter: 'vision',
      snapshot: snapshot()
    };
    const model = buildPopupViewModel(local);
    root.dataset.toolsOpen = 'true';
    renderPopup(root, model);

    const trust = root.querySelector<HTMLDetailsElement>('.trust-drawer');
    const learning = root.querySelector<HTMLDetailsElement>('.learning-drawer');
    const performance = root.querySelector<HTMLDetailsElement>('.performance-drawer');
    const content = root.querySelector<HTMLElement>('.content-scroll');
    const transcript = root.querySelector<HTMLElement>('.transcript');
    const search = root.querySelector<HTMLInputElement>('[data-input="agent-filter"]');
    expect(trust).not.toBeNull();
    expect(learning).not.toBeNull();
    expect(performance).not.toBeNull();
    expect(content).not.toBeNull();
    expect(transcript).not.toBeNull();
    expect(search).not.toBeNull();

    const trustDrawer = requireElement(trust, 'trust drawer');
    const learningDrawer = requireElement(learning, 'learning drawer');
    const performanceDrawer = requireElement(performance, 'performance drawer');
    const contentScroll = requireElement(content, 'content scroll');
    const transcriptPanel = requireElement(transcript, 'transcript');
    const searchInput = requireElement(search, 'agent search input');
    trustDrawer.open = true;
    learningDrawer.open = true;
    performanceDrawer.open = true;
    contentScroll.scrollTop = 173;
    Object.defineProperties(transcriptPanel, {
      clientHeight: { configurable: true, value: 200 },
      scrollHeight: { configurable: true, value: 900 }
    });
    transcriptPanel.scrollTop = 211;
    searchInput.focus();
    searchInput.setSelectionRange(1, 5, 'forward');

    renderPopup(root, model);

    expect(root.querySelector<HTMLDetailsElement>('.trust-drawer')?.open).toBe(true);
    expect(root.querySelector<HTMLDetailsElement>('.learning-drawer')?.open).toBe(true);
    expect(root.querySelector<HTMLDetailsElement>('.performance-drawer')?.open).toBe(true);
    expect(root.querySelector<HTMLElement>('.content-scroll')?.scrollTop).toBe(173);
    expect(root.querySelector<HTMLElement>('.transcript')?.scrollTop).toBe(211);
    const restoredSearch = root.querySelector<HTMLInputElement>('[data-input="agent-filter"]');
    expect(restoredSearch?.value).toBe('vision');
    expect(document.activeElement).toBe(restoredSearch);
    expect(restoredSearch?.selectionStart).toBe(1);
    expect(restoredSearch?.selectionEnd).toBe(5);
    expect(restoredSearch?.selectionDirection).toBe('forward');
  });

  it('follows new transcript output only from the live edge and preserves action focus', () => {
    const scrollHeightDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'scrollHeight');
    const clientHeightDescriptor = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'clientHeight');
    Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
      configurable: true,
      get: function (this: HTMLElement): number {
        return this.classList.contains('transcript') ? 900 : 0;
      }
    });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
      configurable: true,
      get: function (this: HTMLElement): number {
        return this.classList.contains('transcript') ? 200 : 0;
      }
    });

    try {
      const root = document.createElement('div');
      document.body.append(root);
      const model = buildPopupViewModel({
        ...createInitialPopupState(),
        initialized: true,
        snapshot: snapshot()
      });
      renderPopup(root, model);

      const transcript = root.querySelector<HTMLElement>('.transcript');
      const approval = root.querySelector<HTMLButtonElement>('[data-action="approval:approval-1:allow_session"]');
      expect(transcript).not.toBeNull();
      expect(approval).not.toBeNull();
      requireElement(transcript, 'transcript').scrollTop = 690;
      requireElement(approval, 'approval action').focus();

      renderPopup(root, model);

      expect(root.querySelector<HTMLElement>('.transcript')?.scrollTop).toBe(900);
      expect(document.activeElement).toBe(root.querySelector('[data-action="approval:approval-1:allow_session"]'));
    } finally {
      if (scrollHeightDescriptor) {
        Object.defineProperty(HTMLElement.prototype, 'scrollHeight', scrollHeightDescriptor);
      } else {
        Reflect.deleteProperty(HTMLElement.prototype, 'scrollHeight');
      }
      if (clientHeightDescriptor) {
        Object.defineProperty(HTMLElement.prototype, 'clientHeight', clientHeightDescriptor);
      } else {
        Reflect.deleteProperty(HTMLElement.prototype, 'clientHeight');
      }
    }
  });

  it('renders graceful empty, offline, unsupported, watch, and no-agent states', () => {
    const root = document.createElement('div');
    renderPopup(root, buildPopupViewModel(createInitialPopupState()));
    expect(root.getAttribute('aria-busy')).toBe('true');
    expect(root.textContent).toContain('No active page');
    expect(root.querySelector('.empty-state')).not.toBeNull();

    const offlineSnapshot = snapshot({
      bridge: {
        connection: 'disconnected',
        gatewayReady: false,
        killSwitchEnabled: false,
        agents: []
      },
      mode: 'watch',
      page: {
        ...snapshotPage(),
        permission: 'unsupported'
      },
      transcript: [],
      approvals: [],
      activity: [],
      running: false
    });
    const model = buildPopupViewModel({
      ...createInitialPopupState(),
      initialized: true,
      snapshot: offlineSnapshot
    });
    root.dataset.toolsOpen = 'true';
    renderPopup(root, model);
    expect(root.getAttribute('aria-busy')).toBe('false');
    expect(root.textContent).toContain('Offline');
    expect(root.textContent).toContain('No compatible agents found');
    expect(root.querySelector('.composer')).not.toBeNull();
    expect(root.querySelector<HTMLTextAreaElement>('.composer-input')?.readOnly).toBe(true);
    expect(root.querySelector('.disabled-reason')?.textContent).toMatch(/Open the OpenBurnBar app/u);
    expect(root.querySelector('.shell')?.getAttribute('data-tools-open')).toBe('true');
    expect(root.querySelectorAll('.composer')).toHaveLength(1);
    expect(root.querySelector('.popup-tools')?.nextElementSibling).toBe(root.querySelector('.composer'));
    expect(root.querySelector('.popup-tools')?.textContent).toContain('No run activity yet.');

    root.dataset.toolsOpen = 'true';
    renderPopup(
      root,
      buildPopupViewModel({
        ...createInitialPopupState(),
        initialized: true,
        draft: 'Summarize this page',
        snapshot: snapshot({
          page: { ...snapshotPage(), permission: 'denied' }
        })
      })
    );
    expect(root.querySelector('.trust-drawer .drawer-status')?.textContent).toBe('Safari access needed');
    expect(root.querySelector('.trust-drawer .drawer-status')?.textContent).not.toBe('This site allowed');
    expect(root.querySelector<HTMLButtonElement>('.composer-submit')?.disabled).toBe(true);
  });
});
