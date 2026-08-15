import { SafariExtensionError } from '../src/shared/errors';
import { isContentRequest, type PopupResponse } from '../src/shared/messages';
import type { BridgePopupActionResult, ContentAction, NativeCommand } from '../src/shared/protocol';
import { SAFARI_PERFORMANCE_STORAGE_KEY } from '../src/background/performance';
import { parseJSONRecord, requireNativeRequest, requireRecord } from './helpers/assertions';
import {
  agents,
  authorizeCloudScreenshots,
  bootstrap,
  createControllerHarness,
  defaultUISnapshot,
  expectSuccess
} from './helpers/controllerHarness';

type NativeCommandOverrides = Omit<Partial<NativeCommand>, 'targetTabId'> & {
  targetTabId?: number | undefined;
};

function command(
  action: NativeCommand['action'],
  argumentsValue: Record<string, unknown> = {},
  overrides: NativeCommandOverrides = {}
): NativeCommand {
  const omitTarget = Object.hasOwn(overrides, 'targetTabId') && overrides.targetTabId === undefined;
  const { targetTabId, ...otherOverrides } = overrides;
  return {
    commandId: `command-${action}-${crypto.randomUUID()}`,
    sessionId: 'safari-session-1',
    action,
    arguments: argumentsValue,
    issuedAt: new Date(Date.now() - 1_000).toISOString(),
    expiresAt: new Date(Date.now() + 60_000).toISOString(),
    ...otherOverrides,
    ...(omitTarget ? {} : { targetTabId: targetTabId ?? 1 })
  };
}

describe('Safari background controller integration', () => {
  it('publishes the active page before native attachment finishes', async () => {
    const harness = createControllerHarness();
    let releaseHello: (() => void) | undefined;
    const helloBlocked = new Promise<void>((resolve) => {
      releaseHello = resolve;
    });
    harness.setHelloObserver(async () => {
      await helloBlocked;
    });

    const initializing = harness.controller.initialize();
    await vi.waitFor(() => {
      expect(harness.helloCount()).toBe(1);
    });

    const snapshots = harness.controls.runtimeMessages.filter(
      (message): message is { type: 'background.snapshot'; snapshot: PopupResponse['snapshot'] } =>
        typeof message === 'object' && message !== null && Reflect.get(message, 'type') === 'background.snapshot'
    );
    expect(snapshots.at(-1)?.snapshot).toMatchObject({
      bridge: { connection: 'disconnected' },
      busy: true,
      page: {
        tabId: 1,
        title: 'Example',
        url: 'https://example.com/',
        permission: 'prompt'
      }
    });

    releaseHello?.();
    await initializing;
    expect(harness.controller.currentSnapshot()).toMatchObject({
      bridge: { connection: 'connected' },
      page: {
        tabId: 1,
        title: 'Example',
        url: 'https://example.com/',
        permission: 'prompt'
      }
    });
  });

  it('preserves the active page while reporting native attachment failure as offline', async () => {
    const harness = createControllerHarness();
    harness.controls.setNativeHandler(() => {
      throw new Error('native handler unavailable');
    });

    await harness.controller.initialize();

    expect(harness.controller.currentSnapshot()).toMatchObject({
      bridge: { connection: 'disconnected' },
      busy: false,
      page: {
        tabId: 1,
        title: 'Example',
        url: 'https://example.com/',
        permission: 'prompt'
      },
      lastError: {
        code: 'native_bridge_unavailable'
      }
    });
  });

  it('keeps bridge hello valid when Safari reports an empty tab title', async () => {
    const harness = createControllerHarness();
    const activeTab = harness.controls.tabs.get(1);
    if (!activeTab) {
      throw new Error('Expected the mock active Safari tab.');
    }
    activeTab.title = '';

    await harness.controller.initialize();

    const hello = [...harness.controls.nativeMessages]
      .map(requireNativeRequest)
      .find((message) => message.method === 'bridge.hello');
    expect(hello?.params.activePage).toMatchObject({
      url: 'https://example.com/',
      title: 'example.com'
    });
  });

  it('initializes, grants site access, and streams Ask directly through the loopback gateway', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expect(harness.controller.currentSnapshot()).toMatchObject({
      bridge: {
        connection: 'connected',
        gatewayReady: true,
        membership: 'pro'
      },
      selectedAgentId: 'vision-model',
      page: {
        permission: 'prompt'
      }
    });

    const permission = await harness.controller.handlePopupRequest({
      type: 'popup.requestSitePermission'
    });
    expectSuccess(permission);
    expect(permission.snapshot.page?.permission).toBe('granted');
    expect(permission.snapshot.trust.siteAllowed).toBe(true);
    expect(harness.popupCalls.find((call) => call.action === 'trust.update')?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      origin: 'https://example.com',
      decision: 'allow',
      trustMode: 'step'
    });

    await authorizeCloudScreenshots(harness);
    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What color is the call to action?'
    });
    expectSuccess(answer);
    expect(answer.snapshot.transcript.map((entry) => entry.text)).toEqual([
      'What color is the call to action?',
      'The CTA is orange.'
    ]);
    expect(answer.snapshot.transcript.at(-1)).toMatchObject({
      role: 'assistant',
      streaming: false
    });
    expect(answer.snapshot.running).toBe(false);
    expect(harness.gatewayCalls).toHaveLength(1);
    expect(String(harness.gatewayCalls[0]?.input)).toBe('http://127.0.0.1:8317/v1/chat/completions');
    const gatewayBody = parseJSONRecord(String(harness.gatewayCalls[0]?.init?.body), 'gateway body');
    expect(gatewayBody).toMatchObject({ model: 'vision-model', stream: true });
    expect(JSON.stringify(gatewayBody)).not.toContain('controller-loopback-bearer');
    expect(harness.popupCalls.some((call) => call.action === 'ask')).toBe(false);
    expect(harness.popupCalls.some((call) => call.action === 'learning.recall')).toBe(false);
    expect(answer.snapshot.performance?.samples).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ metric: 'native_attach', outcome: 'success' }),
        expect.objectContaining({
          metric: 'viewport_capture',
          outcome: 'success',
          context: { capture: 'viewport' }
        }),
        expect.objectContaining({
          metric: 'image_resize',
          outcome: 'success',
          context: { imagePath: 'content_fallback' }
        }),
        expect.objectContaining({
          metric: 'ask_first_token',
          outcome: 'success',
          context: { route: 'cloud' }
        })
      ])
    );
  });

  it('renews a near-expiry capability through the exact attached native session before Ask', async () => {
    const harness = createControllerHarness();
    harness.setNativeBootstrap({
      ...bootstrap,
      gatewayAttributionCapability: '12'.repeat(32),
      gatewayAttributionExpiresAt: new Date(Date.now() + 1_000).toISOString()
    });
    await harness.controller.initialize();

    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.requestSitePermission'
      })
    );
    harness.setNativeBootstrap({
      ...bootstrap,
      gatewayAttributionCapability: '34'.repeat(32),
      gatewayAttributionExpiresAt: new Date(Date.now() + 5 * 60_000).toISOString()
    });
    await authorizeCloudScreenshots(harness);
    const bootstrapCallsBeforeAsk = harness.popupCalls.filter((call) => call.action === 'bootstrap').length;
    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What color is the call to action?'
    });

    expectSuccess(answer);
    expect(harness.popupCalls.filter((call) => call.action === 'bootstrap')).toHaveLength(bootstrapCallsBeforeAsk + 1);
    expect(harness.gatewayCalls).toHaveLength(1);
    expect(new Headers(harness.gatewayCalls[0]?.init?.headers).get('X-OpenBurnBar-Attribution-Capability')).toBe(
      '34'.repeat(32)
    );
  });

  it('waits for an in-flight native projection before Ask reads its capability', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    let releaseProjection: (() => void) | undefined;
    const projectionBlocked = new Promise<void>((resolve) => {
      releaseProjection = resolve;
    });
    harness.setPopupActionHandler('ui.snapshot', async () => {
      await projectionBlocked;
      return {
        accepted: true,
        output: {
          ...defaultUISnapshot(),
          bootstrap: {
            ...bootstrap,
            gatewayAttributionCapability: '56'.repeat(32)
          }
        }
      };
    });

    const refreshing = harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    await vi.waitFor(() => {
      expect(harness.popupCalls.filter((call) => call.action === 'ui.snapshot').length).toBeGreaterThan(1);
    });
    const asking = harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'Describe the call to action.'
    });
    await Promise.resolve();
    expect(harness.gatewayCalls).toHaveLength(0);

    releaseProjection?.();
    expectSuccess(await refreshing);
    expectSuccess(await asking);
    expect(new Headers(harness.gatewayCalls[0]?.init?.headers).get('X-OpenBurnBar-Attribution-Capability')).toBe(
      '56'.repeat(32)
    );
  });

  it('suppresses capability-rotating projection refreshes while Ask is active', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    let releaseGateway: (() => void) | undefined;
    harness.setGatewayHandler(
      () =>
        new Promise<Response>((resolve) => {
          releaseGateway = () =>
            resolve(
              new Response('{"choices":[{"message":{"content":"Orange."}}]}', {
                status: 200,
                headers: { 'Content-Type': 'application/json' }
              })
            );
        })
    );
    const snapshotCallsBeforeAsk = harness.popupCalls.filter((call) => call.action === 'ui.snapshot').length;
    const asking = harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'Describe the call to action.'
    });
    await vi.waitFor(() => expect(harness.gatewayCalls).toHaveLength(1));

    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.refresh' }));
    expect(harness.popupCalls.filter((call) => call.action === 'ui.snapshot')).toHaveLength(snapshotCallsBeforeAsk);

    releaseGateway?.();
    expectSuccess(await asking);
  });

  it('preserves a completed local Ask transcript when the native snapshot has no run transcript', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);

    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What color is the call to action?'
    });
    expectSuccess(answer);
    expect(answer.snapshot.transcript.map((entry) => entry.text)).toEqual([
      'What color is the call to action?',
      'The CTA is orange.'
    ]);

    harness.setUISnapshot({
      ...defaultUISnapshot(),
      transcript: []
    });
    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.transcript.map((entry) => entry.text)).toEqual([
      'What color is the call to action?',
      'The CTA is orange.'
    ]);
  });

  it('stops during native renewal before DOM or screenshot capture and performs zero provider contact', async () => {
    const harness = createControllerHarness();
    harness.setNativeBootstrap({
      ...bootstrap,
      gatewayAttributionExpiresAt: new Date(Date.now() + 1_000).toISOString()
    });
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    let releaseRenewal: (() => void) | undefined;
    harness.setPopupActionHandler(
      'bootstrap',
      () =>
        new Promise<BridgePopupActionResult>((resolve) => {
          releaseRenewal = () =>
            resolve({
              accepted: true,
              output: {
                ...bootstrap,
                gatewayAttributionCapability: '78'.repeat(32)
              }
            });
        })
    );
    const pageContextCallsBeforeAsk = harness.controls.tabMessages.filter(
      ({ message }) => isContentRequest(message) && message.type === 'content.pageContext'
    ).length;
    const capturesBeforeAsk = harness.controls.captures.length;
    const asking = harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'Describe the call to action.'
    });
    await vi.waitFor(() => {
      expect(harness.popupCalls.filter((call) => call.action === 'bootstrap').length).toBeGreaterThan(1);
    });

    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.abort',
        trigger: 'stop_button'
      })
    );
    releaseRenewal?.();
    expectSuccess(await asking);
    expect(harness.gatewayCalls).toHaveLength(0);
    expect(
      harness.controls.tabMessages.filter(
        ({ message }) => isContentRequest(message) && message.type === 'content.pageContext'
      )
    ).toHaveLength(pageContextCallsBeforeAsk);
    expect(harness.controls.captures).toHaveLength(capturesBeforeAsk);
  });

  it('fails closed without provider contact when native renewal is malformed', async () => {
    const harness = createControllerHarness();
    harness.setNativeBootstrap({
      ...bootstrap,
      gatewayAttributionExpiresAt: new Date(Date.now() + 1_000).toISOString()
    });
    await harness.controller.initialize();

    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.requestSitePermission'
      })
    );
    harness.setNativeBootstrap({
      ...bootstrap,
      gatewayAttributionCapability: 'malformed',
      gatewayAttributionExpiresAt: new Date(Date.now() + 5 * 60_000).toISOString()
    });
    await authorizeCloudScreenshots(harness);
    const bootstrapCallsBeforeAsk = harness.popupCalls.filter((call) => call.action === 'bootstrap').length;
    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What color is the call to action?'
    });

    expect(answer.ok).toBe(false);
    expect(harness.gatewayCalls).toHaveLength(0);
    expect(harness.popupCalls.filter((call) => call.action === 'bootstrap')).toHaveLength(bootstrapCallsBeforeAsk + 1);
  });

  it('records native attach as failed when the daemon negotiates an unsupported protocol', async () => {
    const harness = createControllerHarness();
    harness.setHelloProtocolVersion(2);

    await harness.controller.initialize();

    expect(harness.controller.currentSnapshot()).toMatchObject({
      bridge: {
        connection: 'disconnected'
      },
      lastError: {
        code: 'protocol_mismatch'
      }
    });
    expect(harness.controller.currentSnapshot().performance?.samples).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          metric: 'native_attach',
          outcome: 'error'
        })
      ])
    );
  });

  it('accepts the popup bootstrap measurement without reattaching native state and persists it locally', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const nativeMessageCount = harness.controls.nativeMessages.length;
    const recorded = await harness.controller.handlePopupRequest({
      type: 'popup.recordPerformance',
      metric: 'popup_bootstrap',
      durationMs: 31.25,
      outcome: 'success'
    });
    expectSuccess(recorded);
    expect(harness.controls.nativeMessages).toHaveLength(nativeMessageCount);
    expect(recorded.snapshot.performance?.samples.at(-1)).toMatchObject({
      metric: 'popup_bootstrap',
      durationMs: 31.25,
      outcome: 'success'
    });
    expect(harness.controls.storage.get(SAFARI_PERFORMANCE_STORAGE_KEY)).toMatchObject({
      totalRecorded: expect.any(Number),
      samples: expect.arrayContaining([
        expect.objectContaining({
          metric: 'popup_bootstrap',
          durationMs: 31.25
        })
      ])
    });

    const refreshed = await harness.controller.handlePopupRequest({
      type: 'popup.performanceSnapshot'
    });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.performance?.samples.at(-1)).toMatchObject({
      metric: 'popup_bootstrap',
      durationMs: 31.25
    });
    expect(harness.controls.nativeMessages).toHaveLength(nativeMessageCount);

    const cleared = await harness.controller.handlePopupRequest({
      type: 'popup.clearPerformance'
    });
    expectSuccess(cleared);
    expect(cleared.snapshot.performance).toMatchObject({
      totalRecorded: 0,
      droppedCount: 0,
      samples: [],
      summaries: []
    });
    expect(harness.controls.storage.get(SAFARI_PERFORMANCE_STORAGE_KEY)).toMatchObject({
      totalRecorded: 0,
      droppedCount: 0,
      nextSequence: 1,
      samples: []
    });
    expect(harness.controls.nativeMessages).toHaveLength(nativeMessageCount);
  });

  it('stops Ask streaming immediately, preserves partial text, and keeps Stop intentional', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    harness.setGatewayHandler(async (_input, init) => {
      if (!init?.signal) {
        throw new Error('Expected the gateway request to carry an AbortSignal.');
      }
      const signal = init.signal;
      const encoder = new TextEncoder();
      return new Response(
        new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(
              encoder.encode('data: {"choices":[{"delta":{"content":"A useful partial answer"}}]}\n\n')
            );
            const abort = (): void => {
              controller.error(new DOMException('The operation was aborted.', 'AbortError'));
            };
            if (signal.aborted) {
              abort();
            } else {
              signal.addEventListener('abort', abort, { once: true });
            }
          }
        }),
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' }
        }
      );
    });

    const asking = harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'Stream an answer until I stop it.'
    });
    await vi.waitFor(() => {
      expect(harness.controller.currentSnapshot().transcript.at(-1)?.text).toBe('A useful partial answer');
      expect(harness.controller.currentSnapshot().busy).toBe(true);
    });

    const stopped = await harness.controller.handlePopupRequest({
      type: 'popup.abort',
      trigger: 'popup_shortcut'
    });
    expectSuccess(stopped);
    const answer = await asking;
    expectSuccess(answer);
    expect(answer.snapshot).toMatchObject({
      running: false,
      busy: false
    });
    expect(answer.snapshot.lastError).toBeUndefined();
    expect(answer.snapshot.transcript.at(-1)).toMatchObject({
      role: 'assistant',
      text: 'A useful partial answer',
      streaming: false
    });
    expect(answer.snapshot.transcript.at(-1)?.error).toBeUndefined();
    expect(
      harness.controls.tabMessages.some(
        ({ tabId, message }) => tabId === 1 && isContentRequest(message) && message.type === 'content.abort'
      )
    ).toBe(true);
    expect(harness.popupCalls.filter((call) => call.action === 'abort')).toHaveLength(1);
    expect(stopped.snapshot.performance?.samples).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          metric: 'stop_panic',
          outcome: 'success',
          context: { trigger: 'popup_shortcut' }
        }),
        expect.objectContaining({
          metric: 'ask_first_token',
          outcome: 'success',
          context: { route: 'cloud' }
        })
      ])
    );
  });

  it('recalls only after opt-in and injects bounded learning as supplemental untrusted user context', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setLearning',
        optedIn: true
      })
    );
    const recalled = [
      '## What you know about me',
      '<untrusted-content provenance="safari_learning_recall">',
      '- [memory_id=memory-1; forget_id=proposal-1] Prefers annual totals.',
      '</untrusted-content>'
    ].join('\n');
    harness.setPopupActionResult('learning.recall', {
      accepted: true,
      output: { untrustedContext: recalled }
    });
    const prompt = `Compare the plans without changing this request. ${'😀'.repeat(800)}`;
    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt
    });
    expectSuccess(answer);

    const recall = harness.popupCalls.find((call) => call.action === 'learning.recall');
    expect(recall?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      limit: 8
    });
    expect(new TextEncoder().encode(String(recall?.payload.query)).byteLength).toBeLessThanOrEqual(2 * 1024);
    expect(String(recall?.payload.query)).not.toBe(prompt);

    const gatewayBody = parseJSONRecord(String(harness.gatewayCalls[0]?.init?.body), 'gateway body');
    const messages = Array.isArray(gatewayBody.messages) ? gatewayBody.messages : [];
    const system = requireRecord(messages[0], 'system message').content;
    const user = requireRecord(messages[1], 'user message').content;
    expect(typeof system === 'string' ? system : '').not.toContain('Prefers annual totals.');
    expect(Array.isArray(user) ? user[0]?.text : '').toContain(recalled);
    expect(Array.isArray(user) ? user[0]?.text : '').toContain(prompt);
  });

  it('continues Ask without personalization when recall fails or exceeds the browser bound', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setLearning',
        optedIn: true
      })
    );

    harness.setPopupActionError('learning.recall', new Error('recall temporarily unavailable'));
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.ask',
        prompt: 'First answer without personalization.'
      })
    );
    harness.setPopupActionError('learning.recall', undefined);
    harness.setPopupActionResult('learning.recall', {
      accepted: true,
      output: { untrustedContext: 'x'.repeat(16 * 1024 + 1) }
    });
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.ask',
        prompt: 'Second answer without oversized personalization.'
      })
    );

    expect(harness.gatewayCalls).toHaveLength(2);
    for (const call of harness.gatewayCalls) {
      const body = parseJSONRecord(String(call.init?.body), 'gateway body');
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const user = requireRecord(messages[1], 'user message').content;
      expect(Array.isArray(user) ? user[0]?.text : '').not.toContain('<untrusted_learned_context');
    }
  });

  it('keeps Ask available while the Computer Use kill switch blocks agentic runs', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.requestSitePermission'
      })
    );
    await authorizeCloudScreenshots(harness);
    harness.setUISnapshot({
      ...defaultUISnapshot(),
      killSwitchEnabled: true
    });
    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.trust.globalKillSwitch).toBe(true);

    const answer = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'Describe the visible call to action.'
    });
    expectSuccess(answer);
    expect(harness.gatewayCalls).toHaveLength(1);

    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setMode',
        mode: 'agentic'
      })
    );
    const blocked = await harness.controller.handlePopupRequest({
      type: 'popup.startAgentic',
      prompt: 'Click the call to action.'
    });
    expect(blocked).toMatchObject({
      ok: false,
      error: {
        code: 'kill_switch_enabled'
      },
      snapshot: {
        busy: false
      }
    });
    expect(harness.popupCalls.some((call) => call.action === 'agentic')).toBe(false);
  });

  it('keeps the selected agent compatible with the active mode and rejects crafted incompatible requests', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();

    const handoffMode = await harness.controller.handlePopupRequest({
      type: 'popup.setMode',
      mode: 'handoff'
    });
    expectSuccess(handoffMode);
    expect(handoffMode.snapshot).toMatchObject({
      mode: 'handoff',
      selectedAgentId: 'codex'
    });

    const incompatibleSelection = await harness.controller.handlePopupRequest({
      type: 'popup.selectAgent',
      agentId: 'vision-model'
    });
    expect(incompatibleSelection).toMatchObject({
      ok: false,
      error: {
        code: 'agent_incompatible'
      },
      snapshot: {
        mode: 'handoff',
        selectedAgentId: 'codex'
      }
    });

    const craftedAsk = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'This request did not come from the visible hand-off composer.'
    });
    expect(craftedAsk).toMatchObject({
      ok: false,
      error: {
        code: 'vision_model_required'
      },
      snapshot: {
        mode: 'handoff',
        selectedAgentId: 'codex',
        busy: false,
        transcript: []
      }
    });
    expect(harness.gatewayCalls).toHaveLength(0);
    expect(harness.controls.tabMessages).toHaveLength(0);

    const askMode = await harness.controller.handlePopupRequest({
      type: 'popup.setMode',
      mode: 'ask'
    });
    expectSuccess(askMode);
    expect(askMode.snapshot).toMatchObject({
      mode: 'ask',
      selectedAgentId: 'vision-model'
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      mode: 'ask',
      selectedAgentId: 'vision-model'
    });
  });

  it('uses only the native eligible installed-agent projection for Safari hand-off', async () => {
    const harness = createControllerHarness();
    harness.setUISnapshot({
      ...defaultUISnapshot(),
      catalog: {
        catalog: {
          schemaVersion: 1,
          agents: [
            ...agents,
            {
              id: 'forge',
              displayName: 'Forge',
              providerName: 'Generic catalog',
              kind: 'cli',
              installed: true,
              cloud: false,
              supportsVision: false
            }
          ],
          providers: []
        }
      },
      installedAgents: [
        {
          id: 'codex',
          displayName: 'Codex',
          providerName: 'Installed agents'
        },
        {
          id: 'forge',
          displayName: 'Forge',
          providerName: 'Installed agents'
        },
        {
          id: 'opencode',
          displayName: 'OpenCode',
          providerName: 'Installed agents'
        }
      ]
    });

    await harness.controller.initialize();
    const snapshot = harness.controller.currentSnapshot();
    expect(snapshot.bridge.agents.map((agent) => agent.id)).toEqual(['codex', 'opencode', 'vision-model']);
    expect(snapshot.bridge.agents.find((agent) => agent.id === 'codex')).toMatchObject({
      kind: 'cli',
      installed: true,
      cloud: false,
      supportsVision: false
    });
    expect(snapshot.bridge.agents.some((agent) => agent.id === 'forge')).toBe(false);

    const handoffMode = await harness.controller.handlePopupRequest({
      type: 'popup.setMode',
      mode: 'handoff'
    });
    expectSuccess(handoffMode);
    expect(handoffMode.snapshot.selectedAgentId).toBe('codex');
    const blockedSelection = await harness.controller.handlePopupRequest({
      type: 'popup.selectAgent',
      agentId: 'forge'
    });
    expect(blockedSelection).toMatchObject({
      ok: false,
      error: {
        code: 'agent_unknown'
      }
    });
  });

  it('does not recover Safari hand-off agents from an older generic catalog snapshot', async () => {
    const harness = createControllerHarness();
    const legacySnapshot = defaultUISnapshot();
    delete legacySnapshot.installedAgents;
    harness.setUISnapshot({
      ...legacySnapshot,
      catalog: {
        catalog: {
          schemaVersion: 1,
          agents,
          providers: []
        }
      }
    });

    await harness.controller.initialize();
    const snapshot = harness.controller.currentSnapshot();
    expect(snapshot.bridge.agents.map((agent) => agent.id)).toEqual(['vision-model']);

    const handoffMode = await harness.controller.handlePopupRequest({
      type: 'popup.setMode',
      mode: 'handoff'
    });
    expectSuccess(handoffMode);
    expect(handoffMode.snapshot.selectedAgentId).toBeUndefined();
  });

  it('repairs a persisted selection that is incompatible with its persisted mode', async () => {
    const harness = createControllerHarness();
    harness.controls.storage.set('openburnbar.safari.preferences.v1', {
      mode: 'handoff',
      selectedAgentId: 'vision-model',
      onlyCurrentTab: true,
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: false,
      learningOptedIn: false,
      learningConsentSeen: false,
      sites: {}
    });

    await harness.controller.initialize();

    expect(harness.controller.currentSnapshot()).toMatchObject({
      mode: 'handoff',
      selectedAgentId: 'codex'
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      mode: 'handoff',
      selectedAgentId: 'codex'
    });
  });

  it.each([
    {
      phase: 'completed',
      tone: 'success',
      text: 'The installed agent hand-off completed.',
      errorMessage: undefined
    },
    {
      phase: 'failed',
      tone: 'error',
      text: 'The installed agent hand-off failed. The installed CLI exited unsuccessfully.',
      errorMessage: 'The installed CLI exited unsuccessfully.'
    },
    {
      phase: 'cancelled',
      tone: 'warning',
      text: 'The installed agent hand-off was cancelled.',
      errorMessage: undefined
    }
  ] as const)(
    'requests and visibly reconciles an active hand-off that becomes $phase',
    async ({ phase, tone, text, errorMessage }) => {
      const harness = createControllerHarness();
      await harness.controller.initialize();
      expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
      expectSuccess(
        await harness.controller.handlePopupRequest({
          type: 'popup.setMode',
          mode: 'handoff'
        })
      );
      const handoff = await harness.controller.handlePopupRequest({
        type: 'popup.handoff',
        prompt: 'Prepare a read-only briefing.'
      });
      expectSuccess(handoff);

      harness.setUISnapshot({
        ...defaultUISnapshot(),
        run: {
          runID: 'run-handoff',
          modelID: 'cli:codex',
          phase: 'awaiting_approval'
        },
        approvals: {
          requests: [
            {
              approvalId: 'approval-terminal',
              runId: 'run-handoff',
              actionSummary: 'Confirm the stale approval is cleared'
            }
          ]
        }
      });
      const awaitingApproval = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
      expectSuccess(awaitingApproval);
      expect(awaitingApproval.snapshot.approvals).toHaveLength(1);

      harness.setUISnapshot({
        ...defaultUISnapshot(),
        run: {
          runID: 'run-handoff',
          modelID: 'cli:codex',
          phase,
          ...(errorMessage ? { errorMessage } : {})
        },
        running: true
      });
      const terminal = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
      expectSuccess(terminal);
      expect(harness.popupCalls.filter((call) => call.action === 'ui.snapshot').at(-1)?.payload).toEqual({
        safariSessionId: 'safari-session-1',
        runId: 'run-handoff'
      });
      expect(terminal.snapshot).toMatchObject({
        running: false,
        approvals: [],
        bridge: {
          activeRunId: 'run-handoff'
        }
      });
      expect(terminal.snapshot.activity.at(-1)).toMatchObject({
        id: `run-terminal:run-handoff:${phase}`,
        runId: 'run-handoff',
        text,
        tone
      });

      const repeated = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
      expectSuccess(repeated);
      expect(
        repeated.snapshot.activity.filter((event) => event.id === `run-terminal:run-handoff:${phase}`)
      ).toHaveLength(1);
    }
  );

  it('uses canonical trust and learning mutations, mirrors approvals, launches runs, and unifies local and native Stop', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.requestSitePermission'
      })
    );
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { siteAllowed: true, sensitiveSiteOverride: true, onlyCurrentTab: false }
      })
    );
    await authorizeCloudScreenshots(harness);

    const agentic = await harness.controller.handlePopupRequest({
      type: 'popup.startAgentic',
      prompt: 'Find the least expensive option.'
    });
    expectSuccess(agentic);
    expect(agentic.snapshot.running).toBe(true);
    expect(agentic.snapshot.bridge.activeRunId).toBe('run-agentic');

    const stopped = await harness.controller.handlePopupRequest({
      type: 'popup.abort',
      trigger: 'stop_button'
    });
    expectSuccess(stopped);
    expect(stopped.snapshot.running).toBe(false);
    expect(
      harness.controls.tabMessages.some(({ message }) => isContentRequest(message) && message.type === 'content.abort')
    ).toBe(true);

    const restarted = await harness.controller.handlePopupRequest({
      type: 'popup.startAgentic',
      prompt: 'Start a new verified run after the stopped session.'
    });
    expectSuccess(restarted);
    expect(restarted.snapshot.running).toBe(true);

    const handoffMode = await harness.controller.handlePopupRequest({
      type: 'popup.setMode',
      mode: 'handoff'
    });
    expectSuccess(handoffMode);
    expect(handoffMode.snapshot.selectedAgentId).toBe('codex');
    const handoff = await harness.controller.handlePopupRequest({
      type: 'popup.handoff',
      prompt: 'Prepare a read-only briefing.'
    });
    expectSuccess(handoff);
    expect(handoff.snapshot.bridge.activeRunId).toBe('run-handoff');
    expect(handoff.snapshot.running).toBe(true);
    expect(handoff.snapshot.activity.at(-1)?.text).toBe(
      'The private page briefing was handed to the selected local agent.'
    );

    harness.setUISnapshot({
      ...defaultUISnapshot(),
      run: {
        runID: 'run-handoff',
        phase: 'awaiting_approval'
      },
      approvals: {
        requests: [
          {
            approvalId: 'approval-1',
            runId: 'run-handoff',
            sessionId: 'computer-use-session',
            toolKind: 'safari_click',
            title: 'Click Buy',
            message: 'The agent wants to click Buy.',
            actionSummary: 'Click the Buy button',
            requestedAt: '2026-08-10T12:00:00Z'
          }
        ]
      },
      learning: {
        enabled: true,
        tier: 'burnbar_pro',
        proposals: [
          {
            proposalId: 'proposal-1',
            version: 4,
            kind: 'skill',
            title: 'Compare prices',
            content: 'Compare visible prices before choosing.',
            reviewStatus: 'proposed',
            createdAt: '2026-08-10T12:00:00Z'
          }
        ]
      }
    });
    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.approvals[0]).toMatchObject({
      id: 'approval-1',
      runId: 'run-handoff',
      summary: 'Click the Buy button'
    });
    expect(refreshed.snapshot.learning.items[0]).toMatchObject({
      id: 'proposal-1',
      version: 4,
      status: 'proposed'
    });

    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.approval',
        approvalId: 'approval-1',
        decision: 'allow_once'
      })
    );
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setLearning',
        optedIn: true
      })
    );
    const approved = await harness.controller.handlePopupRequest({
      type: 'popup.learningReview',
      itemId: 'proposal-1',
      decision: 'approve'
    });
    expectSuccess(approved);
    expect(approved.snapshot.learning.items[0]).toMatchObject({
      version: 5,
      status: 'accepted'
    });
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.learningReview',
        itemId: 'proposal-1',
        decision: 'forget'
      })
    );
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setLearning',
        optedIn: false
      })
    );

    const trustCall = harness.popupCalls.find(
      (call) => call.action === 'trust.update' && typeof call.payload.origin === 'string'
    );
    expect(trustCall?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      origin: 'https://example.com',
      decision: 'allow',
      trustMode: 'step'
    });
    expect(harness.popupCalls.find((call) => call.action === 'learning.optIn')?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      consentVersion: 1
    });
    expect(harness.popupCalls.find((call) => call.action === 'learning.approve')?.payload).toMatchObject({
      proposalId: 'proposal-1',
      expectedVersion: 4
    });
    expect(harness.popupCalls.find((call) => call.action === 'learning.forget')?.payload).toMatchObject({
      proposalId: 'proposal-1',
      expectedVersion: 5
    });
    expect(harness.popupCalls.find((call) => call.action === 'learning.optOut')?.payload).toMatchObject({
      deleteLearnedProfile: true
    });
    expect(harness.popupCalls.filter((call) => call.action === 'abort')).toHaveLength(1);
    const learningMetrics = harness.controller
      .currentSnapshot()
      .performance?.samples.filter((sample) => sample.metric === 'learning_mutation');
    expect(learningMetrics?.map((sample) => sample.context?.learningOperation)).toEqual(
      expect.arrayContaining(['opt_in', 'approve', 'forget', 'opt_out'])
    );
    expect(learningMetrics?.every((sample) => sample.outcome === 'success')).toBe(true);
    expect(
      harness.controller
        .currentSnapshot()
        .performance?.samples.some(
          (sample) =>
            sample.metric === 'learning_load' &&
            sample.outcome === 'success' &&
            sample.context?.learningOperation === 'load'
        )
    ).toBe(true);
  });

  it('does not count a compatible snapshot without a learning projection as a successful learning load', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const snapshotWithoutLearning = defaultUISnapshot();
    delete snapshotWithoutLearning.learning;
    harness.setUISnapshot(snapshotWithoutLearning);

    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.bridge).toMatchObject({
      connection: 'connected',
      membership: 'pro'
    });
    expect(
      refreshed.snapshot.performance?.samples.filter((sample) => sample.metric === 'learning_load').at(-1)
    ).toMatchObject({
      outcome: 'error',
      context: {
        learningOperation: 'load'
      }
    });
  });

  it('does not apply or count a rejected native snapshot as a successful learning load', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    harness.setPopupActionResult('ui.snapshot', {
      accepted: false,
      output: {
        ...defaultUISnapshot(),
        killSwitchEnabled: true,
        learning: {
          enabled: true,
          tier: 'burnbar_pro',
          proposals: [
            {
              proposalId: 'rejected-proposal',
              version: 1,
              kind: 'skill',
              title: 'Rejected projection',
              content: 'This rejected state must not reach the popup.',
              reviewStatus: 'proposed',
              createdAt: '2026-08-12T12:00:00Z'
            }
          ]
        }
      }
    });

    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(refreshed);
    expect(refreshed.snapshot.trust.globalKillSwitch).toBe(false);
    expect(refreshed.snapshot.learning.items).toEqual([]);
    expect(
      refreshed.snapshot.performance?.samples.filter((sample) => sample.metric === 'learning_load').at(-1)
    ).toMatchObject({
      outcome: 'error',
      context: {
        learningOperation: 'load'
      }
    });
  });

  it('derives gateway readiness from validated embedded bootstrap data', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    harness.setUISnapshot({
      ...defaultUISnapshot(),
      gatewayReady: true,
      bootstrap: {
        ...bootstrap,
        gatewayAttributionCapability: 'malformed'
      }
    });

    const refreshed = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });

    expectSuccess(refreshed);
    expect(refreshed.snapshot.bridge.gatewayReady).toBe(false);
    expect(refreshed.snapshot.lastError?.code).toBe('gateway_attribution_capability_invalid');
  });

  it('retains a fail-closed local halt when native Stop confirmation fails until a new Agentic run succeeds', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: {
          siteAllowed: true,
          sensitiveSiteOverride: true,
          cloudScreenshotAcknowledged: true
        }
      })
    );
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.setMode', mode: 'agentic' }));
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.startAgentic',
        prompt: 'Begin a verified run.'
      })
    );

    harness.setUISnapshot({
      ...defaultUISnapshot(),
      run: {
        runID: 'run-agentic',
        phase: 'awaiting_approval'
      },
      approvals: {
        requests: [
          {
            approvalId: 'approval-before-stop',
            runId: 'run-agentic',
            sessionId: 'computer-use-session',
            toolKind: 'safari_click',
            title: 'Click Buy',
            message: 'The agent wants to click Buy.',
            actionSummary: 'Click the Buy button',
            requestedAt: '2026-08-10T12:00:00Z'
          }
        ]
      }
    });
    const projected = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(projected);
    expect(projected.snapshot.running).toBe(true);
    expect(projected.snapshot.approvals).toHaveLength(1);

    harness.setPopupActionError('abort', new Error('The daemon connection dropped.'));
    const stopped = await harness.controller.handlePopupRequest({
      type: 'popup.abort',
      trigger: 'stop_button'
    });
    expect(stopped).toMatchObject({
      ok: false,
      snapshot: {
        running: false,
        busy: false,
        approvals: []
      }
    });
    expect(
      harness.controls.tabMessages.some(({ message }) => isContentRequest(message) && message.type === 'content.abort')
    ).toBe(true);

    const staleProjection = await harness.controller.handlePopupRequest({ type: 'popup.refresh' });
    expectSuccess(staleProjection);
    expect(staleProjection.snapshot.running).toBe(false);
    expect(staleProjection.snapshot.approvals).toEqual([]);

    harness.commands.push(command('click', { selector: '#buy' }, { expectedNavigationEpoch: 7 }));
    await harness.controller.pollOnce();
    expect(harness.completions.at(-1)).toMatchObject({
      ok: false,
      error: expect.stringMatching(/stopped locally/u)
    });
    expect(harness.contentActions).toEqual([]);

    harness.setPopupActionError('abort', undefined);
    const restarted = await harness.controller.handlePopupRequest({
      type: 'popup.startAgentic',
      prompt: 'Begin a genuinely new verified run.'
    });
    expectSuccess(restarted);
    expect(restarted.snapshot.running).toBe(true);

    harness.commands.push(command('click', { selector: '#buy' }, { expectedNavigationEpoch: 7 }));
    await harness.controller.pollOnce();
    expect(harness.completions.at(-1)).toMatchObject({ ok: true });
    expect(harness.contentActions.map((action) => action.kind)).toEqual(['click']);
  });

  it('stages only an explicit correction for the exact active page and projects it immediately', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));

    const beforeOptIn = await harness.controller.handlePopupRequest({
      type: 'popup.teachCorrection',
      correction: 'Always compare annual totals before monthly prices.'
    });
    expect(beforeOptIn).toMatchObject({
      ok: false,
      error: { code: 'learning_not_enabled' }
    });
    expect(harness.popupCalls.some((call) => call.action === 'learning.propose')).toBe(false);

    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.setLearning', optedIn: true }));
    harness.setPopupActionResult('learning.propose', {
      accepted: true,
      output: {
        proposal: {
          proposalId: 'proposal-correction-1',
          version: 1,
          kind: 'memory',
          title: 'Price comparison preference',
          content: 'Always compare annual totals before monthly prices.',
          reviewStatus: 'proposed',
          createdAt: '2026-08-10T19:00:00Z'
        }
      }
    });
    const staged = await harness.controller.handlePopupRequest({
      type: 'popup.teachCorrection',
      correction: '  Always compare annual totals before monthly prices.  '
    });
    expectSuccess(staged);
    expect(staged.snapshot.learning.items[0]).toMatchObject({
      id: 'proposal-correction-1',
      version: 1,
      kind: 'memory',
      status: 'proposed',
      summary: 'Always compare annual totals before monthly prices.'
    });
    expect(staged.snapshot.activity.at(-1)?.text).toContain('Nothing was activated automatically');

    const proposalCall = harness.popupCalls.find((call) => call.action === 'learning.propose');
    expect(proposalCall?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      correction: 'Always compare annual totals before monthly prices.',
      tabId: 1,
      url: 'https://example.com/'
    });
    expect(proposalCall?.payload.correctionId).toEqual(expect.any(String));
    expect(Object.keys(proposalCall?.payload ?? {}).sort()).toEqual(
      ['correction', 'correctionId', 'safariSessionId', 'tabId', 'url'].sort()
    );
    expect(JSON.stringify(proposalCall?.payload)).not.toContain('method');
    expect(JSON.stringify(proposalCall?.payload)).not.toContain('screenshot');
    expect(JSON.stringify(proposalCall?.payload)).not.toContain('pageContext');

    const activeTab = harness.controls.tabs.get(1);
    if (activeTab) {
      activeTab.url = 'https://example.com/changed';
    }
    const stale = await harness.controller.handlePopupRequest({
      type: 'popup.teachCorrection',
      correction: 'This must stay bound to the original active page.'
    });
    expect(stale).toMatchObject({
      ok: false,
      error: { code: 'learning_page_stale' }
    });
    expect(harness.popupCalls.filter((call) => call.action === 'learning.propose')).toHaveLength(1);
  });

  it('commits site trust only after native acceptance and never persists rejected changes later', async () => {
    const harness = createControllerHarness();
    const originalPreferences = {
      mode: 'ask' as const,
      selectedAgentId: 'vision-model',
      onlyCurrentTab: true,
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: false,
      learningOptedIn: false,
      learningConsentSeen: false,
      sites: {
        'https://example.com': {
          allowed: true,
          sensitiveOverride: false
        }
      }
    };
    harness.controls.storage.set('openburnbar.safari.preferences.v1', structuredClone(originalPreferences));
    await harness.controller.initialize();
    expect(harness.controller.currentSnapshot().trust).toMatchObject({
      siteAllowed: true,
      sensitiveSiteOverride: false,
      onlyCurrentTab: true
    });

    harness.setPopupActionResult('trust.update', { accepted: false, output: {} });
    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.setTrust',
      patch: {
        siteAllowed: false,
        sensitiveSiteOverride: true,
        onlyCurrentTab: false
      }
    });
    expect(rejected).toMatchObject({
      ok: false,
      error: {
        code: 'trust_update_rejected'
      },
      snapshot: {
        trust: {
          siteAllowed: true,
          sensitiveSiteOverride: false,
          onlyCurrentTab: true
        }
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual(originalPreferences);

    const acknowledged = await harness.controller.handlePopupRequest({
      type: 'popup.setTrust',
      patch: { cloudScreenshotAcknowledged: true }
    });
    expectSuccess(acknowledged);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual({
      ...originalPreferences,
      cloudScreenshotDisclosureAcknowledged: true
    });
  });

  it('binds newly granted loopback website access to daemon trust before persisting it locally', async () => {
    const harness = createControllerHarness();
    const activeTab = harness.controls.tabs.get(1);
    if (!activeTab) {
      throw new Error('Expected the mock active Safari tab.');
    }
    activeTab.url = 'http://127.0.0.1:42771/mixed';
    activeTab.title = 'Mixed Content Fixture';
    await harness.controller.initialize();

    const granted = await harness.controller.handlePopupRequest({
      type: 'popup.requestSitePermission'
    });

    expectSuccess(granted);
    expect(granted.snapshot.page).toMatchObject({
      url: 'http://127.0.0.1:42771/mixed',
      permission: 'granted'
    });
    expect(granted.snapshot.trust.siteAllowed).toBe(true);
    expect(harness.popupCalls.find((call) => call.action === 'trust.update')?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      origin: 'http://127.0.0.1:42771',
      decision: 'allow',
      trustMode: 'step'
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      sites: {
        'http://127.0.0.1:42771': {
          allowed: true,
          sensitiveOverride: false
        }
      }
    });
  });

  it('authorizes Safari, exact native trust, durable future-site setup, and cloud disclosure in one request', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');

    const authorized = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expectSuccess(authorized);
    expect(harness.controls.grantedOrigins).toEqual(new Set(['http://*/*', 'https://*/*']));
    expect(harness.popupCalls.find((call) => call.action === 'trust.update')?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      origin: 'https://example.com',
      decision: 'allow',
      trustMode: 'step'
    });
    expect(authorized.snapshot).toMatchObject({
      page: { permission: 'granted' },
      trust: {
        siteAllowed: true,
        onlyCurrentTab: true,
        cloudScreenshotAcknowledged: true
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: true,
      onlyCurrentTab: true,
      sites: {
        'https://example.com': {
          allowed: true,
          sensitiveOverride: false
        }
      }
    });
  });

  it('reattaches and retries native trust exactly once when the daemon replaced the Safari session', async () => {
    const harness = createControllerHarness();
    harness.setHelloSessionIds(['safari-session-old', 'safari-session-new']);
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    harness.setPopupActionNativeErrors('trust.update', [
      {
        code: 'daemon_rejected',
        message: 'The OpenBurnBar daemon rejected the Safari request.',
        retryable: false,
        details: { daemonCode: -32001 }
      }
    ]);

    const authorized = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expectSuccess(authorized);
    const trustCalls = harness.popupCalls.filter((call) => call.action === 'trust.update');
    expect(trustCalls).toHaveLength(2);
    expect(trustCalls.map((call) => call.payload.safariSessionId)).toEqual([
      'safari-session-old',
      'safari-session-new'
    ]);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: true,
      sites: {
        'https://example.com': {
          allowed: true
        }
      }
    });
  });

  it('defers forced initialization until recovered native trust commits', async () => {
    const harness = createControllerHarness();
    harness.setHelloSessionIds(['safari-session-old', 'safari-session-retry', 'safari-session-refresh']);
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    harness.setPopupActionNativeErrors('trust.update', [
      {
        code: 'daemon_rejected',
        message: 'The OpenBurnBar daemon rejected the Safari request.',
        retryable: false,
        details: { daemonCode: -32001 }
      }
    ]);
    let forcedInitialization: Promise<void> | undefined;
    harness.setHelloObserver((_sessionId, helloCount) => {
      if (helloCount === 2) {
        forcedInitialization = harness.controller.initialize(true);
      }
    });

    const authorized = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expectSuccess(authorized);
    expect(harness.helloCount()).toBe(2);
    expect(
      harness.popupCalls.filter((call) => call.action === 'trust.update').map((call) => call.payload.safariSessionId)
    ).toEqual(['safari-session-old', 'safari-session-retry']);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: true,
      sites: {
        'https://example.com': {
          allowed: true
        }
      }
    });

    await forcedInitialization;
    expect(harness.helloCount()).toBe(3);
  });

  it('surfaces the daemon code and persists nothing when the one session retry is also rejected', async () => {
    const harness = createControllerHarness();
    harness.setHelloSessionIds(['safari-session-old', 'safari-session-new']);
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    harness.setPopupActionNativeErrors('trust.update', [
      {
        code: 'daemon_rejected',
        message: 'The OpenBurnBar daemon rejected the Safari request.',
        retryable: false,
        details: { daemonCode: -32001 }
      },
      {
        code: 'daemon_rejected',
        message: 'The OpenBurnBar daemon rejected the Safari request.',
        retryable: false,
        details: { daemonCode: -32001 }
      }
    ]);

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: {
        code: 'daemon_rejected',
        details: { daemonCode: -32001 }
      },
      snapshot: {
        trust: {
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      }
    });
    expect(harness.popupCalls.filter((call) => call.action === 'trust.update')).toHaveLength(2);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      automaticallyTrustInvokedWebsites: false,
      cloudScreenshotDisclosureAcknowledged: false,
      sites: {}
    });
  });

  it('requires cloud screenshot disclosure acknowledgment inside the unified permission transaction', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: false,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: { code: 'cloud_disclosure_not_acknowledged' }
    });
    expect(harness.popupCalls.some((call) => call.action === 'trust.update')).toBe(false);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      cloudScreenshotDisclosureAcknowledged: false,
      sites: {}
    });
  });

  it('does not persist page or cloud trust when the native authority rejects unified setup', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    harness.setPopupActionResult('trust.update', { accepted: false, output: {} });

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: { code: 'trust_update_rejected' },
      snapshot: {
        trust: {
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      automaticallyTrustInvokedWebsites: false,
      cloudScreenshotDisclosureAcknowledged: false,
      sites: {}
    });
  });

  it('rolls native trust back and remains retryable when local permission persistence fails', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    const baselinePreferences = structuredClone(harness.controls.storage.get('openburnbar.safari.preferences.v1'));
    harness.controls.setStorageSetError(new Error('local storage unavailable'));

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: { code: 'popup_request_failed', message: 'local storage unavailable' },
      snapshot: {
        trust: {
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      }
    });
    expect(
      harness.popupCalls.filter((call) => call.action === 'trust.update').map((call) => call.payload.decision)
    ).toEqual(['allow', 'remove']);
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual(baselinePreferences);

    harness.controls.setStorageSetError(undefined);
    const retrySnapshot = rejected.snapshot;
    if (!retrySnapshot) {
      throw new Error('Expected a fail-closed snapshot for retry.');
    }
    const retryPage = retrySnapshot.page;
    if (!retryPage) {
      throw new Error('Expected the page to remain available for retry.');
    }
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.authorizePage',
        expectedStateVersion: retrySnapshot.stateVersion,
        expectedTabId: retryPage.tabId,
        expectedOrigin: 'https://example.com',
        acknowledgeCloudScreenshots: true,
        websiteAccessGranted: true
      })
    );
  });

  it('fails closed when local persistence fails and native trust rollback is rejected', async () => {
    const harness = createControllerHarness();
    harness.setPopupActionHandler('trust.update', (payload) => ({
      accepted: payload.decision !== 'remove',
      output: {}
    }));
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    const baselinePreferences = structuredClone(harness.controls.storage.get('openburnbar.safari.preferences.v1'));
    harness.controls.setStorageSetError(new Error('local storage unavailable'));

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: {
        code: 'authorization_partial_failure',
        retryable: true,
        details: {
          rollback: { code: 'trust_rollback_rejected' }
        }
      },
      snapshot: {
        trust: {
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual(baselinePreferences);
  });

  it('fails closed with the daemon code when local persistence fails and native rollback throws', async () => {
    const harness = createControllerHarness();
    harness.setPopupActionHandler('trust.update', (payload) => {
      if (payload.decision === 'remove') {
        throw new SafariExtensionError('daemon_rejected', 'The OpenBurnBar daemon rejected the Safari request.', {
          details: { daemonCode: -32603 }
        });
      }
      return { accepted: true, output: {} };
    });
    await harness.controller.initialize();
    const before = harness.controller.currentSnapshot();
    const page = before.page;
    if (!page) {
      throw new Error('Expected an active page.');
    }
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    const baselinePreferences = structuredClone(harness.controls.storage.get('openburnbar.safari.preferences.v1'));
    harness.controls.setStorageSetError(new Error('local storage unavailable'));

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: before.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: 'https://example.com',
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: {
        code: 'authorization_partial_failure',
        retryable: true,
        details: {
          daemonCode: -32603,
          rollback: {
            code: 'native_bridge_unavailable'
          }
        }
      },
      snapshot: {
        trust: {
          siteAllowed: false,
          cloudScreenshotAcknowledged: false
        }
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual(baselinePreferences);
  });

  it('persists nothing when Safari denies or falsely reports unified website access', async () => {
    for (const websiteAccessGranted of [false, true]) {
      const harness = createControllerHarness();
      await harness.controller.initialize();
      const before = harness.controller.currentSnapshot();
      const page = before.page;
      if (!page) {
        throw new Error('Expected an active page.');
      }

      const rejected = await harness.controller.handlePopupRequest({
        type: 'popup.authorizePage',
        expectedStateVersion: before.stateVersion,
        expectedTabId: page.tabId,
        expectedOrigin: 'https://example.com',
        acknowledgeCloudScreenshots: true,
        websiteAccessGranted
      });

      expect(rejected).toMatchObject({
        ok: false,
        error: {
          code: websiteAccessGranted ? 'authorization_verification_failed' : 'site_permission_denied'
        },
        snapshot: {
          trust: {
            siteAllowed: false,
            cloudScreenshotAcknowledged: false
          }
        }
      });
      expect(harness.popupCalls.some((call) => call.action === 'trust.update')).toBe(false);
      expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
        automaticallyTrustInvokedWebsites: false,
        cloudScreenshotDisclosureAcknowledged: false,
        sites: {}
      });
    }
  });

  it('silently registers a future origin after the user enables one-time website setup', async () => {
    const harness = createControllerHarness();
    harness.controls.grantedOrigins.add('http://*/*');
    harness.controls.grantedOrigins.add('https://*/*');
    harness.controls.storage.set('openburnbar.safari.preferences.v1', {
      mode: 'ask',
      selectedAgentId: 'vision-model',
      onlyCurrentTab: true,
      automaticallyTrustInvokedWebsites: true,
      cloudScreenshotDisclosureAcknowledged: true,
      learningOptedIn: false,
      learningConsentSeen: false,
      sites: {}
    });
    const activeTab = harness.controls.tabs.get(1);
    if (!activeTab) {
      throw new Error('Expected an active page.');
    }
    activeTab.url = 'https://future.example/path';
    activeTab.title = 'Future site';

    await harness.controller.initialize();

    expect(harness.controller.currentSnapshot()).toMatchObject({
      page: {
        url: 'https://future.example/path',
        permission: 'granted'
      },
      trust: {
        siteAllowed: true,
        cloudScreenshotAcknowledged: true,
        onlyCurrentTab: true
      }
    });
    expect(
      harness.popupCalls.find(
        (call) => call.action === 'trust.update' && call.payload.origin === 'https://future.example'
      )?.payload
    ).toMatchObject({
      decision: 'allow',
      trustMode: 'step'
    });
  });

  it('does not persist newly granted Safari website access when daemon trust rejects it', async () => {
    const harness = createControllerHarness();
    const activeTab = harness.controls.tabs.get(1);
    if (!activeTab) {
      throw new Error('Expected the mock active Safari tab.');
    }
    activeTab.url = 'http://127.0.0.1:42771/mixed';
    activeTab.title = 'Mixed Content Fixture';
    await harness.controller.initialize();
    harness.setPopupActionResult('trust.update', { accepted: false, output: {} });

    const rejected = await harness.controller.handlePopupRequest({
      type: 'popup.requestSitePermission'
    });

    expect(rejected).toMatchObject({
      ok: false,
      error: {
        code: 'trust_update_rejected'
      },
      snapshot: {
        trust: {
          siteAllowed: false
        }
      }
    });
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toMatchObject({
      sites: {}
    });
  });

  it('never sends unowned tab URL or title metadata through poll, list, active-page, or completion payloads', async () => {
    const harness = createControllerHarness();
    const secretURL = 'https://private.example.test/account?token=recognizable-secret';
    const secretTitle = 'Recognizable private account title';
    harness.controls.tabs.set(2, {
      id: 2,
      windowId: 10,
      active: false,
      currentWindow: true,
      url: secretURL,
      title: secretTitle,
      status: 'complete'
    });
    await harness.controller.initialize();

    await harness.controller.pollOnce();
    const firstPoll = [...harness.controls.nativeMessages]
      .reverse()
      .map(requireNativeRequest)
      .find((message) => message.method === 'bridge.poll');
    expect(firstPoll?.params.knownTabs).toEqual([
      expect.objectContaining({
        tabId: 1,
        url: 'https://example.com/',
        isOwned: true
      })
    ]);
    expect(JSON.stringify(firstPoll)).not.toContain(secretURL);
    expect(JSON.stringify(firstPoll)).not.toContain(secretTitle);

    harness.commands.push(command('list_tabs', {}, { targetTabId: undefined }));
    await harness.controller.pollOnce();
    const listCompletion = harness.completions.at(-1);
    expect(listCompletion?.result).toEqual([
      expect.objectContaining({
        tabId: 1,
        url: 'https://example.com/',
        isOwned: true
      })
    ]);
    expect(listCompletion?.tabs).toEqual([
      expect.objectContaining({
        tabId: 1,
        url: 'https://example.com/',
        isOwned: true
      })
    ]);
    expect(JSON.stringify(listCompletion)).not.toContain(secretURL);
    expect(JSON.stringify(listCompletion)).not.toContain(secretTitle);

    const handedTab = harness.controls.tabs.get(1);
    const privateTab = harness.controls.tabs.get(2);
    if (handedTab) {
      handedTab.active = false;
    }
    if (privateTab) {
      privateTab.active = true;
    }
    await harness.controller.pollOnce();
    const privateTabPoll = [...harness.controls.nativeMessages]
      .reverse()
      .map(requireNativeRequest)
      .find((message) => message.method === 'bridge.poll');
    expect(privateTabPoll?.params).not.toHaveProperty('activePage');
    expect(JSON.stringify(privateTabPoll)).not.toContain(secretURL);
    expect(JSON.stringify(privateTabPoll)).not.toContain(secretTitle);
  });

  it('polls and completes the full Safari command surface with ownership, epoch, URL, consent, and session checks', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { onlyCurrentTab: false }
      })
    );

    const mappedActions: Array<{
      action: NativeCommand['action'];
      arguments: Record<string, unknown>;
      expectedKind: ContentAction['kind'];
    }> = [
      {
        action: 'click',
        arguments: { positionX: 120, positionY: 240, button: 'left', clickCount: 2 },
        expectedKind: 'click'
      },
      {
        action: 'type',
        arguments: { text: 'Mercury', clear: true, submit: false },
        expectedKind: 'type'
      },
      {
        action: 'press_key',
        arguments: { selector: '#query', key: 'K', modifiers: ['Meta'] },
        expectedKind: 'press_key'
      },
      { action: 'scroll', arguments: { deltaY: 320, behavior: 'smooth' }, expectedKind: 'scroll' },
      { action: 'hover', arguments: { selector: '#buy' }, expectedKind: 'hover' },
      { action: 'focus', arguments: { selector: '#query' }, expectedKind: 'focus' },
      {
        action: 'select_option',
        arguments: { selector: '#size', value: 'large' },
        expectedKind: 'select_option'
      },
      {
        action: 'wait_for',
        arguments: { selector: '#result', state: 'visible', timeoutMs: 500 },
        expectedKind: 'wait_for'
      },
      {
        action: 'run_javascript',
        arguments: { script: 'return document.title;', approved: true, world: 'isolated' },
        expectedKind: 'run_javascript'
      },
      {
        action: 'extract',
        arguments: { attributes: ['data-sku'], limit: 10 },
        expectedKind: 'extract'
      }
    ];

    harness.commands.push(command('page_context'));
    await harness.controller.pollOnce();
    for (const action of mappedActions) {
      harness.commands.push(
        command(action.action, action.arguments, {
          expectedNavigationEpoch: 7
        })
      );
      await harness.controller.pollOnce();
    }
    harness.commands.push(command('screenshot', {}, { expectedNavigationEpoch: 7 }));
    await harness.controller.pollOnce();
    harness.commands.push(command('list_tabs', {}, { targetTabId: undefined }));
    await harness.controller.pollOnce();
    harness.commands.push(command('full_page_screenshot', { optIn: false }, { expectedNavigationEpoch: 7 }));
    await harness.controller.pollOnce();
    harness.commands.push(command('click', { selector: '#buy' }, { expectedNavigationEpoch: 999 }));
    await harness.controller.pollOnce();
    harness.commands.push(
      command('navigate', { operation: 'url', url: 'javascript:alert(1)' }, { expectedNavigationEpoch: 7 })
    );
    await harness.controller.pollOnce();
    harness.commands.push(
      command('navigate', { operation: 'url', url: 'https://openburnbar.com/' }, { expectedNavigationEpoch: 7 })
    );
    await harness.controller.pollOnce();
    harness.commands.push(command('open_tab', { url: 'https://example.org/' }, { targetTabId: undefined }));
    await harness.controller.pollOnce();
    harness.commands.push(command('close_tab', {}, { targetTabId: 2 }));
    await harness.controller.pollOnce();
    harness.commands.push(
      command(
        'list_tabs',
        {},
        {
          targetTabId: undefined,
          expiresAt: new Date(Date.now() - 1_000).toISOString()
        }
      )
    );
    await harness.controller.pollOnce();
    harness.commands.push(
      command(
        'list_tabs',
        {},
        {
          targetTabId: undefined,
          sessionId: 'different-session'
        }
      )
    );
    await harness.controller.pollOnce();
    harness.commands.push(command('abort', {}, { targetTabId: undefined }));
    await harness.controller.pollOnce();

    expect(harness.contentActions.map((action) => action.kind)).toEqual(
      mappedActions.map((action) => action.expectedKind)
    );
    expect(harness.contentActions[0]).toMatchObject({
      kind: 'click',
      target: { point: { x: 120, y: 240 } }
    });
    expect(harness.contentActions[1]).toMatchObject({
      kind: 'type',
      text: 'Mercury'
    });
    expect(harness.contentActions[1]).not.toHaveProperty('target');
    expect(harness.contentActions[6]).toMatchObject({
      kind: 'select_option',
      values: ['large']
    });
    expect(harness.contentActions[8]).toMatchObject({
      kind: 'run_javascript',
      source: 'return document.title;',
      approved: true
    });
    expect(harness.contentActions[9]).toMatchObject({
      kind: 'extract',
      selector: 'body'
    });
    expect(harness.completions).toHaveLength(22);
    const successful = harness.completions.filter((completion) => completion.ok === true);
    const failed = harness.completions.filter((completion) => completion.ok === false);
    expect(successful.length).toBeGreaterThanOrEqual(15);
    expect(failed.map((completion) => String(completion.error))).toEqual(
      expect.arrayContaining([
        expect.stringMatching(/explicit approval/u),
        expect.stringMatching(/stale coordinates/u),
        expect.stringMatching(/non-HTTP navigation/u),
        expect.stringMatching(/expired/u),
        expect.stringMatching(/another Safari session/u)
      ])
    );
    expect(harness.controls.tabs.has(2)).toBe(false);
    expect(harness.controls.tabs.get(1)?.url).toBe('https://openburnbar.com/');
    expect(
      harness.controls.tabMessages.some(({ message }) => isContentRequest(message) && message.type === 'content.abort')
    ).toBe(true);
    expect(
      harness.completions.every(
        (completion) =>
          completion.sessionId === 'safari-session-1' &&
          Array.isArray(completion.tabs) &&
          typeof completion.pageState === 'object'
      )
    ).toBe(true);
    const performance = harness.controller.currentSnapshot().performance;
    expect(performance?.samples.some((sample) => sample.metric === 'command_poll')).toBe(true);
    expect(performance?.samples.some((sample) => sample.metric === 'command_completion')).toBe(true);
    expect(
      performance?.samples.some(
        (sample) => sample.metric === 'action_verification' && sample.context?.action === 'click'
      )
    ).toBe(true);
    expect(
      performance?.samples.some(
        (sample) =>
          sample.metric === 'stop_panic' && sample.context?.trigger === 'daemon_abort' && sample.outcome === 'success'
      )
    ).toBe(true);
  });
});
