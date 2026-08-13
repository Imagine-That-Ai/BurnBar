import { SafariBackgroundController } from '../src/background/controller';
import { SafariGatewayClient } from '../src/background/gatewayClient';
import { BrowserNativeMessagingAdapter, NativeBridge } from '../src/background/nativeBridge';
import type { ContentResponse, PopupResponse } from '../src/shared/messages';
import type {
  BridgePopupActionResult,
  ContentAction,
  ContentPageState,
  NativeCommand,
  SafariBootstrapResponse
} from '../src/shared/protocol';
import { createMockBrowser } from './helpers/mockBrowser';

interface NativeRequest {
  protocolVersion: number;
  id: string;
  method: string;
  params: Record<string, unknown>;
}

interface ControllerHarness {
  controller: SafariBackgroundController;
  controls: ReturnType<typeof createMockBrowser>['controls'];
  popupCalls: Array<{ action: string; payload: Record<string, unknown> }>;
  completions: Record<string, unknown>[];
  commands: NativeCommand[];
  gatewayCalls: Array<{ input: RequestInfo | URL; init?: RequestInit }>;
  contentActions: ContentAction[];
  setPopupActionError(action: string, error: Error | undefined): void;
  setPopupActionResult(action: string, result: BridgePopupActionResult): void;
  setUISnapshot(value: Record<string, unknown>): void;
}

const screenshot = {
  dataUrl: 'data:image/jpeg;base64,anBlZw==',
  mediaType: 'image/jpeg' as const,
  width: 1024,
  height: 768,
  byteLength: 4,
  source: 'viewport' as const,
  truncated: false
};

const bootstrap: SafariBootstrapResponse = {
  daemonVersion: '1.0.34',
  protocolVersion: 1,
  gatewayBaseURL: 'http://127.0.0.1:8317',
  gatewayBearerToken: 'controller-loopback-bearer',
  gatewayAvailable: true,
  computerUseAvailable: true,
  learningAvailable: true,
  learningOptedIn: false,
  tier: 'burnbar_pro'
};

const agents = [
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
];

function nativeSuccess(request: NativeRequest, result: unknown): Record<string, unknown> {
  return {
    protocolVersion: 1,
    id: request.id,
    result
  };
}

function pageStateFor(tab: {
  id?: number;
  windowId?: number;
  url?: string;
  title?: string;
  active?: boolean;
}): ContentPageState {
  return {
    url: tab.url ?? '',
    title: tab.title ?? '',
    navigationEpoch: 7,
    isTopFrame: true,
    capturedAt: '2026-08-10T12:00:00Z'
  };
}

function defaultUISnapshot(): Record<string, unknown> {
  return {
    bootstrap,
    catalog: {
      catalog: {
        schemaVersion: 1,
        providers: [
          {
            id: 'cloud',
            displayName: 'Cloud Provider',
            models: [
              {
                id: 'vision-model',
                displayName: 'Vision Model',
                modelCapabilities: { inputModalities: ['text', 'image'] }
              }
            ]
          }
        ]
      }
    },
    membership: {
      membership: {
        tier: 'burnbar_pro'
      }
    },
    safariSession: null,
    run: null,
    approvals: {
      requests: []
    },
    learning: {
      enabled: false,
      tier: 'burnbar_pro',
      proposals: []
    }
  };
}

function createControllerHarness(): ControllerHarness {
  const { browser, controls } = createMockBrowser();
  const popupCalls: Array<{ action: string; payload: Record<string, unknown> }> = [];
  const completions: Record<string, unknown>[] = [];
  const commands: NativeCommand[] = [];
  const gatewayCalls: Array<{ input: RequestInfo | URL; init?: RequestInit }> = [];
  const contentActions: ContentAction[] = [];
  const popupActionErrors = new Map<string, Error>();
  const popupActionResults = new Map<string, BridgePopupActionResult>();
  let uiSnapshot = defaultUISnapshot();

  controls.setContentHandler((tabId, message) => {
    const tab = controls.tabs.get(tabId) ?? {};
    const pageState = pageStateFor(tab);
    const request = message as { type: string; action?: ContentAction; token?: string; y?: number };
    switch (request.type) {
      case 'content.ping':
        return { ok: true, result: { ready: true }, pageState } satisfies ContentResponse;
      case 'content.pageContext':
        return {
          ok: true,
          result: {
            pageState,
            viewport: {
              width: 1024,
              height: 768,
              scrollX: 0,
              scrollY: 0,
              pageWidth: 1024,
              pageHeight: 1600,
              devicePixelRatio: 2,
              visualViewportOffsetLeft: 0,
              visualViewportOffsetTop: 0,
              visualViewportScale: 1
            },
            markdown: '# Example page\n\nA bright orange call to action.',
            snapshot: '[ref=obb-1] [role=button] [name="Buy"] [box=40,80,120,44]',
            nodes: [],
            truncated: false,
            sensitive: false,
            capturedAt: pageState.capturedAt
          },
          pageState
        } satisfies ContentResponse;
      case 'content.execute':
        if (request.action) {
          contentActions.push(request.action);
        }
        return {
          ok: true,
          result: {
            ok: true,
            result: { executed: request.action?.kind },
            pageState,
            verification: {
              url: pageState.url,
              title: pageState.title
            }
          },
          pageState
        } satisfies ContentResponse;
      case 'content.image.resize':
        return {
          ok: true,
          result: screenshot,
          pageState
        } satisfies ContentResponse;
      case 'content.capture.prepare':
        return {
          ok: true,
          result: {
            token: request.token ?? 'capture',
            originalScrollX: 0,
            originalScrollY: 0,
            pageWidth: 1024,
            pageHeight: 1600,
            viewportWidth: 1024,
            viewportHeight: 768,
            devicePixelRatio: 2
          },
          pageState
        } satisfies ContentResponse;
      case 'content.capture.scroll':
        return {
          ok: true,
          result: { scrollX: 0, scrollY: request.y ?? 0 },
          pageState
        } satisfies ContentResponse;
      case 'content.capture.restore':
      case 'content.abort':
        return { ok: true, result: { ready: true }, pageState } satisfies ContentResponse;
      default:
        throw new Error(`Unexpected content request ${request.type}`);
    }
  });

  controls.setNativeHandler((message) => {
    const request = message as NativeRequest;
    switch (request.method) {
      case 'bridge.hello':
        return nativeSuccess(request, {
          sessionId: 'safari-session-1',
          protocolVersion: 1,
          leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
          pollAfterMillis: 200
        });
      case 'bridge.popupAction': {
        const action = String(request.params.action);
        const payload = request.params.payload as Record<string, unknown>;
        popupCalls.push({ action, payload });
        const popupActionError = popupActionErrors.get(action);
        if (popupActionError) {
          throw popupActionError;
        }
        const overriddenResult = popupActionResults.get(action);
        if (overriddenResult) {
          return nativeSuccess(request, overriddenResult);
        }
        if (action === 'bootstrap') {
          return nativeSuccess(request, { accepted: true, output: bootstrap });
        }
        if (action === 'catalog') {
          return nativeSuccess(request, { accepted: true, output: { agents } });
        }
        if (action === 'ui.snapshot') {
          return nativeSuccess(request, { accepted: true, output: uiSnapshot });
        }
        if (action === 'agentic') {
          return nativeSuccess(request, {
            accepted: true,
            output: { runId: 'run-agentic', running: true }
          });
        }
        if (action === 'handoff') {
          return nativeSuccess(request, {
            accepted: true,
            output: { runId: 'run-handoff', phase: 'completed', launched: true, running: false }
          });
        }
        if (action === 'learning.approve') {
          return nativeSuccess(request, {
            accepted: true,
            output: {
              proposal: {
                proposalId: 'proposal-1',
                version: 5,
                kind: 'skill',
                title: 'Compare prices',
                content: 'Compare visible prices before choosing.',
                reviewStatus: 'approved',
                createdAt: '2026-08-10T12:00:00Z'
              }
            }
          });
        }
        return nativeSuccess(request, { accepted: true, output: {} });
      }
      case 'bridge.poll':
        return nativeSuccess(request, {
          ...(commands.length > 0 ? { command: commands.shift() } : {}),
          leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
          pollAfterMillis: 200
        });
      case 'bridge.complete':
        completions.push(request.params);
        return nativeSuccess(request, { accepted: true });
      default:
        throw new Error(`Unexpected native method ${request.method}`);
    }
  });

  const gatewayFetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    gatewayCalls.push({ input, ...(init === undefined ? {} : { init }) });
    const encoder = new TextEncoder();
    return new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encoder.encode('data: {"choices":[{"delta":{"content":"The CTA is orange."}}]}\n\n'));
          controller.enqueue(encoder.encode('data: [DONE]\n\n'));
          controller.close();
        }
      }),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' }
      }
    );
  });
  const gateway = new SafariGatewayClient(gatewayFetcher);
  const bridge = new NativeBridge({
    adapter: new BrowserNativeMessagingAdapter(browser),
    extensionVersion: '1.0.34',
    sessionId: 'extension-instance-test'
  });
  const controller = new SafariBackgroundController(browser, bridge, gateway, {
    startPolling: false
  });

  return {
    controller,
    controls,
    popupCalls,
    completions,
    commands,
    gatewayCalls,
    contentActions,
    setPopupActionError(action, error) {
      if (error) {
        popupActionErrors.set(action, error);
      } else {
        popupActionErrors.delete(action);
      }
    },
    setPopupActionResult(action, result) {
      popupActionResults.set(action, result);
    },
    setUISnapshot(value) {
      uiSnapshot = value;
    }
  };
}

function expectSuccess(response: PopupResponse): asserts response is Extract<PopupResponse, { ok: true }> {
  expect(response.ok, response.ok ? undefined : response.error.message).toBe(true);
}

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

    const cloudNotice = await harness.controller.handlePopupRequest({
      type: 'popup.setTrust',
      patch: { cloudScreenshotAcknowledged: true }
    });
    expectSuccess(cloudNotice);
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
    const gatewayBody = JSON.parse(String(harness.gatewayCalls[0]?.init?.body)) as Record<string, unknown>;
    expect(gatewayBody).toMatchObject({ model: 'vision-model', stream: true });
    expect(JSON.stringify(gatewayBody)).not.toContain('controller-loopback-bearer');
    expect(harness.popupCalls.some((call) => call.action === 'ask')).toBe(false);
    expect(harness.popupCalls.some((call) => call.action === 'learning.recall')).toBe(false);
  });

  it('recalls only after opt-in and injects bounded learning as supplemental untrusted user context', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { cloudScreenshotAcknowledged: true }
      })
    );
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

    const gatewayBody = JSON.parse(String(harness.gatewayCalls[0]?.init?.body)) as {
      messages: Array<{ role: string; content: string | Array<{ type: string; text?: string }> }>;
    };
    const system = gatewayBody.messages[0]?.content;
    const user = gatewayBody.messages[1]?.content;
    expect(typeof system === 'string' ? system : '').not.toContain('Prefers annual totals.');
    expect(Array.isArray(user) ? user[0]?.text : '').toContain(recalled);
    expect(Array.isArray(user) ? user[0]?.text : '').toContain(prompt);
  });

  it('continues Ask without personalization when recall fails or exceeds the browser bound', async () => {
    const harness = createControllerHarness();
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { cloudScreenshotAcknowledged: true }
      })
    );
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
      const body = JSON.parse(String(call.init?.body)) as {
        messages: Array<{ content: string | Array<{ text?: string }> }>;
      };
      const user = body.messages[1]?.content;
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
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { cloudScreenshotAcknowledged: true }
      })
    );
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

  it('repairs a persisted selection that is incompatible with its persisted mode', async () => {
    const harness = createControllerHarness();
    harness.controls.storage.set('openburnbar.safari.preferences.v1', {
      mode: 'handoff',
      selectedAgentId: 'vision-model',
      onlyCurrentTab: true,
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

  it('uses canonical trust and learning mutations, mirrors approvals, launches runs, and sends Stop only natively', async () => {
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
    expectSuccess(
      await harness.controller.handlePopupRequest({
        type: 'popup.setTrust',
        patch: { cloudScreenshotAcknowledged: true }
      })
    );

    const agentic = await harness.controller.handlePopupRequest({
      type: 'popup.startAgentic',
      prompt: 'Find the least expensive option.'
    });
    expectSuccess(agentic);
    expect(agentic.snapshot.running).toBe(true);
    expect(agentic.snapshot.bridge.activeRunId).toBe('run-agentic');

    const stopped = await harness.controller.handlePopupRequest({ type: 'popup.abort' });
    expectSuccess(stopped);
    expect(stopped.snapshot.running).toBe(false);
    expect(
      harness.controls.tabMessages.some(({ message }) => (message as { type?: string }).type === 'content.abort')
    ).toBe(false);

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
    expect(handoff.snapshot.running).toBe(false);
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
    expect(harness.popupCalls.find((call) => call.action === 'abort')?.payload).toMatchObject({
      safariSessionId: 'safari-session-1',
      activeRunId: 'run-agentic',
      reason: 'user_stop'
    });
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
    expect(harness.controls.storage.get('openburnbar.safari.preferences.v1')).toEqual(originalPreferences);
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
    harness.commands.push(command('abort', {}, { targetTabId: undefined }));
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
      harness.controls.tabMessages.some(({ message }) => (message as { type?: string }).type === 'content.abort')
    ).toBe(true);
    expect(
      harness.completions.every(
        (completion) =>
          completion.sessionId === 'safari-session-1' &&
          Array.isArray(completion.tabs) &&
          typeof completion.pageState === 'object'
      )
    ).toBe(true);
  });
});
