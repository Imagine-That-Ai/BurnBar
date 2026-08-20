import {
  isPopupRequest,
  isPopupResponse,
  type PopupRequest,
  type PopupResponse,
  type PopupSnapshot
} from '../src/shared/messages';
import { buildSafariPerformanceDiagnostics } from '../src/shared/performance';
import { createMockBrowser } from './helpers/mockBrowser';
import { requireElement, requireRecord, requireValue, testDOMRect } from './helpers/assertions';

function popupSnapshot(overrides: Partial<PopupSnapshot> = {}): PopupSnapshot {
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
      url: 'https://example.com/',
      title: 'Example',
      navigationEpoch: 1,
      isActive: true,
      isTopFrame: true,
      capturedAt: '2026-08-10T12:00:00Z',
      sensitive: false,
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
          id: 'proposal-1',
          version: 2,
          title: 'Compare prices',
          kind: 'skill',
          status: 'proposed',
          summary: 'Compare visible prices before choosing.',
          createdAt: '2026-08-10T12:00:00Z'
        }
      ]
    },
    transcript: [],
    approvals: [
      {
        id: 'approval-1',
        runId: 'run-1',
        title: 'Click Buy',
        summary: 'Click the Buy button.',
        url: 'https://example.com/',
        risk: 'write',
        requestedAt: '2026-08-10T12:00:00Z'
      }
    ],
    activity: [],
    performance: buildSafariPerformanceDiagnostics(
      {
        schemaVersion: 1,
        retentionLimit: 240,
        totalRecorded: 1,
        droppedCount: 0,
        nextSequence: 2,
        samples: [
          {
            sequence: 1,
            metric: 'native_attach',
            durationMs: 18.5,
            outcome: 'success',
            recordedAt: '2026-08-12T12:00:00Z'
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

async function flushTasks(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

describe('WebExtension runtime entrypoints', () => {
  beforeEach(() => {
    vi.resetModules();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('registers the background listeners and fails closed when the native app is unavailable', async () => {
    const { browser, controls } = createMockBrowser();
    controls.setNativeHandler(() => {
      throw new Error('native app unavailable');
    });
    vi.stubGlobal('browser', browser);

    await import('../src/background/index');
    expect(controls.runtimeMessage.listeners).toHaveLength(1);
    expect(controls.installed.listeners).toHaveLength(1);
    expect(controls.startup.listeners).toHaveLength(1);
    expect(controls.alarm.listeners).toHaveLength(1);

    await expect(controls.emitRuntimeMessage({ type: 'not-popup' })).resolves.toBeUndefined();
    await expect(controls.emitRuntimeMessage({ type: 'popup.unknown' })).resolves.toBeUndefined();
    await expect(controls.emitRuntimeMessage({ type: 'popup.setMode', mode: 'autonomous' })).resolves.toBeUndefined();
    await expect(
      controls.emitRuntimeMessage({ type: 'popup.setTrust', patch: { siteAllowed: 'yes' } })
    ).resolves.toBeUndefined();
    expect(controls.nativeMessages).toHaveLength(0);

    const response = await controls.emitRuntimeMessage({
      type: 'popup.bootstrap'
    });
    if (!isPopupResponse(response)) {
      throw new Error('Expected a valid popup response.');
    }
    expect(response.ok).toBe(true);
    if (!response.ok) {
      throw new Error(response.error.message);
    }
    expect(response.snapshot.bridge.connection).toBe('disconnected');
    expect(response.snapshot.lastError?.code).toBe('native_bridge_unavailable');

    controls.installed.emit();
    controls.startup.emit();
    controls.alarm.emit({ name: 'unrelated' });
    controls.alarm.emit({ name: 'openburnbar-safari-bridge-heartbeat' });
    await flushTasks();
    expect(controls.nativeMessages.length).toBeGreaterThanOrEqual(1);
  });

  it('registers and executes every content-script request branch with structured failures', async () => {
    const { browser, controls } = createMockBrowser();
    vi.stubGlobal('browser', browser);
    document.body.innerHTML = `
      <main>
        <h1>Example page</h1>
        <button id="buy">Buy</button>
        <div class="price" data-sku="one">$10</div>
      </main>
    `;
    vi.spyOn(document.documentElement, 'scrollWidth', 'get').mockReturnValue(1280);
    vi.spyOn(document.documentElement, 'scrollHeight', 'get').mockReturnValue(1600);
    vi.spyOn(document.documentElement, 'clientWidth', 'get').mockReturnValue(1280);
    vi.spyOn(document.documentElement, 'clientHeight', 'get').mockReturnValue(800);
    vi.spyOn(Element.prototype, 'getBoundingClientRect').mockReturnValue(testDOMRect(10, 20, 120, 40));
    vi.spyOn(document.head, 'append').mockImplementation((...nodes: (Node | string)[]) => {
      const node = nodes[0];
      if (node instanceof Node) {
        queueMicrotask(() => node.dispatchEvent(new Event('load')));
      }
    });
    class FakeImage {
      decoding = '';
      src = '';
      naturalWidth = 2000;
      naturalHeight = 1000;

      async decode(): Promise<void> {}
    }
    vi.stubGlobal('Image', FakeImage);
    const createElement = document.createElement.bind(document);
    vi.spyOn(document, 'createElement').mockImplementation((tagName: string, options?: ElementCreationOptions) => {
      if (tagName === 'canvas') {
        const canvas = createElement('canvas');
        Object.defineProperties(canvas, {
          getContext: {
            configurable: true,
            value: vi.fn(() => ({ drawImage: vi.fn() }))
          },
          toDataURL: {
            configurable: true,
            value: vi.fn(() => 'data:image/jpeg;base64,anBlZw==')
          }
        });
        return canvas;
      }
      return createElement(tagName, options);
    });

    await import('../src/content/index');
    await flushTasks();
    expect(controls.runtimeMessage.listeners).toHaveLength(1);
    await expect(controls.emitRuntimeMessage({ type: 'other' })).resolves.toBeUndefined();
    await expect(controls.emitRuntimeMessage({ type: 'content.unknown' })).resolves.toBeUndefined();
    await expect(controls.emitRuntimeMessage({ type: 'content.ping', extra: true })).resolves.toBeUndefined();
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.execute',
        action: { kind: 'click', target: { selector: '#buy' }, unreviewed: true }
      })
    ).resolves.toBeUndefined();
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.image.resize',
        dataUrl: 'data:image/jpeg;base64,c291cmNl',
        maxLongEdge: Number.POSITIVE_INFINITY,
        quality: 82
      })
    ).resolves.toBeUndefined();

    const ping = await controls.emitRuntimeMessage({ type: 'content.ping' });
    expect(ping).toMatchObject({ ok: true, result: { ready: true } });
    const context = await controls.emitRuntimeMessage({ type: 'content.pageContext' });
    expect(context).toMatchObject({
      ok: true,
      result: {
        markdown: expect.stringContaining('Example page'),
        snapshot: expect.stringContaining('[ref=')
      }
    });
    const execution = await controls.emitRuntimeMessage({
      type: 'content.execute',
      action: { kind: 'extract', selector: '.price', attributes: ['data-sku'] }
    });
    expect(execution).toMatchObject({
      ok: true,
      result: {
        ok: true,
        result: [{ text: '$10', attributes: { 'data-sku': 'one' } }]
      }
    });
    await expect(controls.emitRuntimeMessage({ type: 'content.abort', reason: 'test stop' })).resolves.toMatchObject({
      ok: true
    });
    const prepared = requireRecord(
      await controls.emitRuntimeMessage({
        type: 'content.capture.prepare',
        token: 'capture-1'
      }),
      'capture preparation response'
    );
    expect(requireRecord(prepared.result, 'capture preparation result').pageHeight).toBeGreaterThan(0);
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.capture.scroll',
        token: 'capture-1',
        y: 400
      })
    ).resolves.toMatchObject({ ok: true, result: { scrollY: 400 } });
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.capture.restore',
        token: 'capture-1'
      })
    ).resolves.toMatchObject({ ok: true });
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.image.resize',
        dataUrl: 'data:image/jpeg;base64,c291cmNl',
        maxLongEdge: 1568,
        quality: 82
      })
    ).resolves.toMatchObject({
      ok: true,
      result: { width: 1568, height: 784, mediaType: 'image/jpeg' }
    });
    await expect(
      controls.emitRuntimeMessage({
        type: 'content.capture.scroll',
        token: 'stale',
        y: 0
      })
    ).resolves.toMatchObject({
      ok: false,
      error: { code: 'capture_session_invalid' }
    });
  });

  it('wires the popup’s modes, forms, approvals, trust, learning, refresh, push, and panic controls', async () => {
    vi.useFakeTimers();
    const { browser, controls } = createMockBrowser();
    const requests: PopupRequest[] = [];
    const permissionRequest = vi.spyOn(browser.permissions, 'request');
    const clipboardWrite = vi.fn(async (_text: string) => undefined);
    const createObjectURL = vi.fn(() => 'blob:openburnbar-performance');
    const revokeObjectURL = vi.fn();
    class TestURL extends URL {
      static createObjectURL = createObjectURL;
      static revokeObjectURL = revokeObjectURL;
    }
    vi.stubGlobal('URL', TestURL);
    vi.stubGlobal('navigator', {
      clipboard: {
        writeText: clipboardWrite
      }
    });
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => undefined);
    let currentSnapshot = popupSnapshot();
    browser.runtime.sendMessage = vi.fn(async (message: unknown) => {
      if (!isPopupRequest(message)) {
        throw new Error('Expected a valid popup request.');
      }
      const request = message;
      requests.push(request);
      switch (request.type) {
        case 'popup.setMode':
          currentSnapshot = { ...currentSnapshot, mode: request.mode };
          break;
        case 'popup.selectAgent':
          currentSnapshot = { ...currentSnapshot, selectedAgentId: request.agentId };
          break;
        case 'popup.abort':
          currentSnapshot = { ...currentSnapshot, running: false };
          break;
        case 'popup.setTrust':
          currentSnapshot = {
            ...currentSnapshot,
            trust: { ...currentSnapshot.trust, ...request.patch }
          };
          break;
        case 'popup.authorizePage':
          if (!currentSnapshot.page) {
            throw new Error('Expected a current page for permission authorization.');
          }
          currentSnapshot = {
            ...currentSnapshot,
            page: {
              ...currentSnapshot.page,
              permission: 'granted'
            },
            trust: {
              ...currentSnapshot.trust,
              siteAllowed: true,
              cloudScreenshotAcknowledged: request.acknowledgeCloudScreenshots
            }
          };
          break;
        case 'popup.setLearning':
          currentSnapshot = {
            ...currentSnapshot,
            learning: { ...currentSnapshot.learning, optedIn: request.optedIn }
          };
          break;
        case 'popup.clearPerformance':
          currentSnapshot = {
            ...currentSnapshot,
            performance: buildSafariPerformanceDiagnostics(
              {
                schemaVersion: 1,
                retentionLimit: 240,
                totalRecorded: 0,
                droppedCount: 0,
                nextSequence: 1,
                samples: []
              },
              'ready'
            )
          };
          break;
      }
      return { ok: true, snapshot: currentSnapshot } satisfies PopupResponse;
    });
    vi.stubGlobal('browser', browser);
    document.body.innerHTML = '<div id="app"></div>';

    await import('../src/popup/index');
    await flushTasks();
    const root = requireElement(document.getElementById('app'), 'popup root');
    expect(requests[0]).toEqual({ type: 'popup.bootstrap' });
    expect(requests).toContainEqual({
      type: 'popup.recordPerformance',
      metric: 'popup_bootstrap',
      durationMs: expect.any(Number),
      outcome: 'success'
    });
    expect(root.querySelector('.composer')).not.toBeNull();
    expect(root.querySelector('.popup-tools')).toBeNull();

    const shapeToggle = requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="toggle-popup-shape"]'),
      'popup shape toggle'
    );
    expect(shapeToggle.getAttribute('aria-pressed')).toBe('true');
    shapeToggle.click();
    expect(root.querySelector<HTMLElement>('.shell')?.dataset.popupShape).toBe('compact');
    expect(document.documentElement.dataset.popupShape).toBe('compact');
    expect(
      root.querySelector<HTMLButtonElement>('[data-action="toggle-popup-shape"]')?.getAttribute('aria-pressed')
    ).toBe('false');
    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="toggle-popup-shape"]'),
      'compact popup shape toggle'
    ).click();
    expect(root.querySelector<HTMLElement>('.shell')?.dataset.popupShape).toBe('expanded');
    expect(document.documentElement.dataset.popupShape).toBe('expanded');

    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="toggle-mode-popover"]'),
      'mode popover trigger'
    ).click();
    expect(root.querySelector<HTMLElement>('#mode-popover')?.hidden).toBe(false);
    const modeRange = requireElement(root.querySelector<HTMLInputElement>('[data-input="mode-range"]'), 'mode range');
    expect(modeRange.getAttribute('aria-valuetext')).toBe('Ask');
    modeRange.focus();
    const setModeCountBeforeInput = requests.filter((request) => request.type === 'popup.setMode').length;
    modeRange.value = '2';
    modeRange.dispatchEvent(new Event('input', { bubbles: true }));
    expect(modeRange.isConnected).toBe(true);
    expect(document.activeElement).toBe(modeRange);
    expect(modeRange.getAttribute('aria-valuetext')).toBe('Watch');
    expect(root.querySelector('.mode-popover-value')?.textContent).toBe('Watch');
    expect(root.querySelector('.mode-description')?.textContent).toContain('approve from Safari');
    expect(root.querySelector<HTMLElement>('.mode-track')?.style.getPropertyValue('--mode-fraction')).toBe(
      String(2 / 3)
    );
    expect(requests.filter((request) => request.type === 'popup.setMode')).toHaveLength(setModeCountBeforeInput);
    modeRange.dispatchEvent(new Event('change', { bubbles: true }));
    await flushTasks();
    expect(requests).toContainEqual({ type: 'popup.setMode', mode: 'watch' });
    expect(root.querySelector<HTMLElement>('#mode-popover')?.hidden).toBe(true);
    requireElement(root.querySelector<HTMLButtonElement>('[data-action="mode:ask"]'), 'Ask mode').click();
    await flushTasks();

    requireElement(root.querySelector<HTMLButtonElement>('[data-action="toggle-tools"]'), 'popup tools').click();
    expect(root.querySelector('.popup-tools')?.getAttribute('aria-label')).toBe('OpenBurnBar controls');
    expect(root.querySelector<HTMLButtonElement>('[data-action="toggle-tools"]')?.getAttribute('aria-expanded')).toBe(
      'true'
    );
    expect(root.querySelector('[data-action="toggle-tools"]')?.getAttribute('aria-controls')).toBe('popup-tools');
    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="diagnostics-copy"]'),
      'copy diagnostics'
    ).click();
    await flushTasks();
    expect(clipboardWrite).toHaveBeenCalledOnce();
    const copiedJSON = String(clipboardWrite.mock.calls[0]?.[0]);
    expect(copiedJSON).toContain('"localOnly": true');
    expect(copiedJSON).not.toContain('https://example.com/');

    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="diagnostics-download"]'),
      'download diagnostics'
    ).click();
    await flushTasks();
    expect(createObjectURL).toHaveBeenCalledOnce();
    vi.advanceTimersByTime(0);
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:openburnbar-performance');

    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="diagnostics-clear"]'),
      'clear diagnostics'
    ).click();
    expect(root.querySelector<HTMLButtonElement>('[data-action="diagnostics-clear"]')?.textContent).toContain(
      'Confirm clear'
    );
    requireElement(root.querySelector<HTMLButtonElement>('[data-action="diagnostics-clear"]'), 'confirm clear').click();
    await flushTasks();
    expect(currentSnapshot.performance).toMatchObject({
      totalRecorded: 0,
      droppedCount: 0,
      samples: [],
      summaries: []
    });

    const draft = requireElement(root.querySelector<HTMLTextAreaElement>('[data-input="draft"]'), 'Ask draft');
    draft.value = 'What color is the CTA?';
    draft.dispatchEvent(new Event('input', { bubbles: true }));
    requireElement(root.querySelector<HTMLFormElement>('[data-form="composer"]'), 'Ask form').dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true })
    );
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.ask',
      prompt: 'What color is the CTA?'
    });

    requireElement(root.querySelector<HTMLButtonElement>('[data-action="mode:agentic"]'), 'Agentic mode').click();
    await flushTasks();
    const agenticDraft = requireElement(
      root.querySelector<HTMLTextAreaElement>('[data-input="draft"]'),
      'Agentic draft'
    );
    agenticDraft.value = 'Find the cheapest option';
    agenticDraft.dispatchEvent(new Event('input', { bubbles: true }));
    requireElement(root.querySelector<HTMLFormElement>('[data-form="composer"]'), 'Agentic form').dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true })
    );
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.startAgentic',
      prompt: 'Find the cheapest option'
    });

    requireElement(root.querySelector<HTMLButtonElement>('[data-action="mode:handoff"]'), 'Handoff mode').click();
    await flushTasks();
    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="toggle-model-picker"]'),
      'model picker'
    ).click();
    expect(root.querySelector<HTMLElement>('#model-picker-options')?.hidden).toBe(false);
    const codexOption = requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="select-agent"][data-agent-id="codex"]'),
      'Codex option'
    );
    expect(codexOption.getAttribute('role')).toBe('option');
    expect(codexOption.getAttribute('aria-label')).toContain('local');
    codexOption.click();
    await flushTasks();
    expect(requests).toContainEqual({ type: 'popup.selectAgent', agentId: 'codex' });
    const handoffDraft = requireElement(
      root.querySelector<HTMLTextAreaElement>('[data-input="draft"]'),
      'Handoff draft'
    );
    handoffDraft.value = 'Prepare a briefing';
    handoffDraft.dispatchEvent(new Event('input', { bubbles: true }));
    requireElement(root.querySelector<HTMLFormElement>('[data-form="composer"]'), 'Handoff form').dispatchEvent(
      new Event('submit', { bubbles: true, cancelable: true })
    );
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.handoff',
      prompt: 'Prepare a briefing'
    });

    currentSnapshot = {
      ...currentSnapshot,
      stateVersion: currentSnapshot.stateVersion + 1,
      mode: 'ask',
      selectedAgentId: 'vision-model',
      page: {
        ...requireValue(currentSnapshot.page, 'current popup page'),
        sensitive: true,
        permission: 'prompt'
      },
      trust: {
        ...currentSnapshot.trust,
        siteAllowed: false,
        cloudScreenshotAcknowledged: false
      },
      lastError: {
        code: 'temporary_test_error',
        message: 'Retry the popup projection.',
        retryable: true
      }
    };
    controls.runtimeMessage.emit(
      {
        type: 'background.snapshot',
        snapshot: currentSnapshot
      },
      {}
    );
    await flushTasks();

    expect(root.textContent).toContain('Choosing Allow & continue acknowledges this disclosure.');
    const permissionSheetAction = requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="complete-permission-setup"]'),
      'unified permission action'
    );
    permissionSheetAction.click();
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.authorizePage',
      expectedStateVersion: currentSnapshot.stateVersion,
      expectedTabId: 1,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });
    expect(permissionRequest).toHaveBeenCalledWith({
      origins: ['http://*/*', 'https://*/*']
    });
    const authorizationMessageOrder = vi
      .mocked(browser.runtime.sendMessage)
      .mock.invocationCallOrder.find((_, index) => {
        const message: unknown = vi.mocked(browser.runtime.sendMessage).mock.calls[index]?.[0];
        return isPopupRequest(message) && message.type === 'popup.authorizePage';
      });
    expect(permissionRequest.mock.invocationCallOrder[0]).toBeLessThan(
      requireValue(authorizationMessageOrder, 'authorization message invocation order')
    );

    for (const [inputName, patchKey] of [
      ['trust-site', 'siteAllowed'],
      ['trust-tab', 'onlyCurrentTab'],
      ['trust-sensitive', 'sensitiveSiteOverride'],
      ['trust-kill', 'globalKillSwitch']
    ] as const) {
      const input = requireElement(
        root.querySelector<HTMLInputElement>(`[data-input="${inputName}"]`),
        `${inputName} input`
      );
      input.checked = !input.checked;
      input.dispatchEvent(new Event('change', { bubbles: true }));
      await flushTasks();
      expect(
        requests.some((request) => request.type === 'popup.setTrust' && typeof request.patch[patchKey] === 'boolean')
      ).toBe(true);
    }
    expect(root.querySelector('[data-input="trust-cloud"]')).toBeNull();

    const correctionDraft = requireElement(
      root.querySelector<HTMLTextAreaElement>('[data-input="correction-draft"]'),
      'correction draft'
    );
    correctionDraft.value = 'Always compare annual totals before monthly prices.';
    correctionDraft.dispatchEvent(new Event('input', { bubbles: true }));
    requireElement(
      root.querySelector<HTMLFormElement>('[data-form="learning-correction"]'),
      'learning correction form'
    ).dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.teachCorrection',
      correction: 'Always compare annual totals before monthly prices.'
    });
    expect(root.querySelector<HTMLTextAreaElement>('[data-input="correction-draft"]')?.value).toBe('');

    const learningToggle = requireElement(
      root.querySelector<HTMLInputElement>('[data-input="learning-opt-in"]'),
      'learning opt-in'
    );
    learningToggle.checked = false;
    learningToggle.dispatchEvent(new Event('change', { bubbles: true }));
    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="approval:approval-1:allow_once"]'),
      'allow-once approval'
    ).click();
    requireElement(
      root.querySelector<HTMLButtonElement>('[data-action="learning:proposal-1:approve"]'),
      'approve learning'
    ).click();
    requireElement(root.querySelector<HTMLButtonElement>('[data-action="refresh"]'), 'refresh button').click();
    requireElement(root.querySelector<HTMLButtonElement>('[data-action="abort"]'), 'abort button').click();
    await flushTasks();

    root.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: '.',
        ctrlKey: true,
        altKey: true,
        metaKey: true,
        bubbles: true
      })
    );
    const keyboardDraft = root.querySelector<HTMLTextAreaElement>('[data-input="draft"]');
    if (keyboardDraft) {
      keyboardDraft.value = 'Keyboard submit';
      keyboardDraft.dispatchEvent(new Event('input', { bubbles: true }));
      keyboardDraft.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', metaKey: true, bubbles: true }));
    }
    await flushTasks();

    controls.runtimeMessage.emit(
      {
        type: 'background.snapshot',
        snapshot: popupSnapshot({ stateVersion: 99, mode: 'watch' })
      },
      {}
    );
    controls.runtimeMessage.emit({ type: 'unrelated.push' }, {});
    await flushTasks();
    expect(root.textContent).toContain('Watch');

    vi.advanceTimersByTime(5_000);
    await flushTasks();
    expect(requests.some((request) => request.type === 'popup.refresh')).toBe(true);
    expect(requests).toEqual(
      expect.arrayContaining([
        { type: 'popup.selectAgent', agentId: 'codex' },
        { type: 'popup.approval', approvalId: 'approval-1', decision: 'allow_once' },
        {
          type: 'popup.teachCorrection',
          correction: 'Always compare annual totals before monthly prices.'
        },
        { type: 'popup.learningReview', itemId: 'proposal-1', decision: 'approve' },
        { type: 'popup.setLearning', optedIn: false },
        {
          type: 'popup.authorizePage',
          expectedStateVersion: 2,
          expectedTabId: 1,
          expectedOrigin: 'https://example.com',
          acknowledgeCloudScreenshots: true,
          websiteAccessGranted: true
        },
        { type: 'popup.performanceSnapshot' },
        { type: 'popup.clearPerformance' },
        { type: 'popup.abort', trigger: 'stop_button' },
        { type: 'popup.abort', trigger: 'popup_shortcut' }
      ])
    );
  });
});
