import type { PopupRequest, PopupResponse, PopupSnapshot } from '../src/shared/messages';
import { createMockBrowser } from './helpers/mockBrowser';

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

    const response = (await controls.emitRuntimeMessage({
      type: 'popup.bootstrap'
    })) as PopupResponse;
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
    vi.spyOn(Element.prototype, 'getBoundingClientRect').mockReturnValue({
      x: 10,
      y: 20,
      left: 10,
      top: 20,
      width: 120,
      height: 40,
      right: 130,
      bottom: 60,
      toJSON: () => ({})
    } as DOMRect);
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
    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string) => {
      if (tagName === 'canvas') {
        return {
          width: 0,
          height: 0,
          getContext: () => ({ drawImage: vi.fn() }),
          toDataURL: () => 'data:image/jpeg;base64,anBlZw=='
        } as unknown as HTMLCanvasElement;
      }
      return createElement(tagName);
    }) as typeof document.createElement);

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
    const prepared = (await controls.emitRuntimeMessage({
      type: 'content.capture.prepare',
      token: 'capture-1'
    })) as { result: { pageHeight: number } };
    expect(prepared.result.pageHeight).toBeGreaterThan(0);
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
    let currentSnapshot = popupSnapshot();
    browser.runtime.sendMessage = vi.fn(async (message: unknown) => {
      const request = message as PopupRequest;
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
        case 'popup.setLearning':
          currentSnapshot = {
            ...currentSnapshot,
            learning: { ...currentSnapshot.learning, optedIn: request.optedIn }
          };
          break;
      }
      return { ok: true, snapshot: currentSnapshot } satisfies PopupResponse;
    });
    vi.stubGlobal('browser', browser);
    document.body.innerHTML = '<div id="app"></div>';

    await import('../src/popup/index');
    await flushTasks();
    const root = document.getElementById('app')!;
    expect(requests[0]).toEqual({ type: 'popup.bootstrap' });
    expect(root.querySelector('.composer')).not.toBeNull();

    const draft = root.querySelector<HTMLTextAreaElement>('[data-input="draft"]')!;
    draft.value = 'What color is the CTA?';
    draft.dispatchEvent(new Event('input', { bubbles: true }));
    root
      .querySelector<HTMLFormElement>('[data-form="composer"]')!
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.ask',
      prompt: 'What color is the CTA?'
    });

    root.querySelector<HTMLButtonElement>('[data-action="mode:agentic"]')!.click();
    await flushTasks();
    const agenticDraft = root.querySelector<HTMLTextAreaElement>('[data-input="draft"]')!;
    agenticDraft.value = 'Find the cheapest option';
    agenticDraft.dispatchEvent(new Event('input', { bubbles: true }));
    root
      .querySelector<HTMLFormElement>('[data-form="composer"]')!
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.startAgentic',
      prompt: 'Find the cheapest option'
    });

    root.querySelector<HTMLButtonElement>('[data-action="mode:handoff"]')!.click();
    await flushTasks();
    const agentSelect = root.querySelector<HTMLSelectElement>('[data-input="agent"]')!;
    agentSelect.value = 'codex';
    agentSelect.dispatchEvent(new Event('change', { bubbles: true }));
    await flushTasks();
    const handoffDraft = root.querySelector<HTMLTextAreaElement>('[data-input="draft"]')!;
    handoffDraft.value = 'Prepare a briefing';
    handoffDraft.dispatchEvent(new Event('input', { bubbles: true }));
    root
      .querySelector<HTMLFormElement>('[data-form="composer"]')!
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.handoff',
      prompt: 'Prepare a briefing'
    });

    currentSnapshot = {
      ...currentSnapshot,
      mode: 'ask',
      selectedAgentId: 'vision-model',
      page: {
        ...currentSnapshot.page!,
        sensitive: true,
        permission: 'prompt'
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

    for (const [inputName, patchKey] of [
      ['trust-site', 'siteAllowed'],
      ['trust-tab', 'onlyCurrentTab'],
      ['trust-sensitive', 'sensitiveSiteOverride'],
      ['trust-cloud', 'cloudScreenshotAcknowledged'],
      ['trust-kill', 'globalKillSwitch']
    ] as const) {
      const input = root.querySelector<HTMLInputElement>(`[data-input="${inputName}"]`)!;
      input.checked = !input.checked;
      input.dispatchEvent(new Event('change', { bubbles: true }));
      await flushTasks();
      expect(
        requests.some((request) => request.type === 'popup.setTrust' && typeof request.patch[patchKey] === 'boolean')
      ).toBe(true);
    }

    const correctionDraft = root.querySelector<HTMLTextAreaElement>('[data-input="correction-draft"]')!;
    correctionDraft.value = 'Always compare annual totals before monthly prices.';
    correctionDraft.dispatchEvent(new Event('input', { bubbles: true }));
    root
      .querySelector<HTMLFormElement>('[data-form="learning-correction"]')!
      .dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
    await flushTasks();
    expect(requests).toContainEqual({
      type: 'popup.teachCorrection',
      correction: 'Always compare annual totals before monthly prices.'
    });
    expect(root.querySelector<HTMLTextAreaElement>('[data-input="correction-draft"]')?.value).toBe('');

    const learningToggle = root.querySelector<HTMLInputElement>('[data-input="learning-opt-in"]')!;
    learningToggle.checked = false;
    learningToggle.dispatchEvent(new Event('change', { bubbles: true }));
    root.querySelector<HTMLButtonElement>('[data-action="approval:approval-1:allow_once"]')!.click();
    root.querySelector<HTMLButtonElement>('[data-action="learning:proposal-1:approve"]')!.click();
    root.querySelector<HTMLButtonElement>('[data-action="refresh"]')!.click();
    root.querySelector<HTMLButtonElement>('[data-action="request-permission"]')!.click();
    root.querySelector<HTMLButtonElement>('[data-action="abort"]')!.click();
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
        { type: 'popup.requestSitePermission' },
        { type: 'popup.abort' }
      ])
    );
  });
});
