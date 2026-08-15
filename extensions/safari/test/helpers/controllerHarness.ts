import { expect, vi } from 'vitest';

import { SafariBackgroundController } from '../../src/background/controller';
import { SafariGatewayClient } from '../../src/background/gatewayClient';
import { BrowserNativeMessagingAdapter, NativeBridge } from '../../src/background/nativeBridge';
import type { SerializedError } from '../../src/shared/errors';
import { isContentRequest, type ContentResponse, type PopupResponse } from '../../src/shared/messages';
import type {
  BridgePopupActionResult,
  ContentAction,
  ContentPageState,
  NativeCommand,
  SafariBootstrapResponse
} from '../../src/shared/protocol';
import { createMockBrowser } from './mockBrowser';
import { requireNativeRequest, requireRecord } from './assertions';

// Shared harness for the background controller. It is deliberately free of
// DOM assumptions so the same harness can drive the controller both under
// jsdom (controller.test.ts) and under a plain worker-like Node environment
// (controller.serviceWorker.test.ts) that mirrors the MV3 service worker.
type NativeRequest = ReturnType<typeof requireNativeRequest>;

type GatewayHandler = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

interface ControllerHarness {
  controller: SafariBackgroundController;
  controls: ReturnType<typeof createMockBrowser>['controls'];
  popupCalls: Array<{ action: string; payload: Record<string, unknown> }>;
  completions: Record<string, unknown>[];
  commands: NativeCommand[];
  gatewayCalls: Array<{ input: RequestInfo | URL; init?: RequestInit }>;
  contentActions: ContentAction[];
  setPopupActionError(action: string, error: Error | undefined): void;
  setPopupActionNativeErrors(action: string, errors: SerializedError[]): void;
  setPopupActionHandler(
    action: string,
    handler:
      | ((payload: Record<string, unknown>) => BridgePopupActionResult | Promise<BridgePopupActionResult>)
      | undefined
  ): void;
  setPopupActionResult(action: string, result: BridgePopupActionResult): void;
  setGatewayHandler(handler: GatewayHandler): void;
  setNativeBootstrap(value: SafariBootstrapResponse): void;
  setHelloProtocolVersion(protocolVersion: number): void;
  setHelloSessionIds(sessionIds: string[]): void;
  helloCount(): number;
  setHelloObserver(observer: ((sessionId: string, helloCount: number) => void | Promise<void>) | undefined): void;
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

export const bootstrap: SafariBootstrapResponse = {
  daemonVersion: '1.0.34',
  protocolVersion: 1,
  gatewayBaseURL: 'http://127.0.0.1:8317',
  gatewayBearerToken: 'controller-loopback-bearer',
  gatewayAttributionCapability: 'ab'.repeat(32),
  gatewayAttributionExpiresAt: '2099-08-12T23:59:59.000Z',
  gatewayAvailable: true,
  computerUseAvailable: true,
  learningAvailable: true,
  learningOptedIn: false,
  tier: 'burnbar_pro'
};

export const agents = [
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

export function defaultUISnapshot(): Record<string, unknown> {
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
    installedAgents: [
      {
        id: 'codex',
        displayName: 'Codex',
        providerName: 'Installed agents'
      }
    ],
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

export function createControllerHarness(): ControllerHarness {
  const { browser, controls } = createMockBrowser();
  const popupCalls: Array<{ action: string; payload: Record<string, unknown> }> = [];
  const completions: Record<string, unknown>[] = [];
  const commands: NativeCommand[] = [];
  const gatewayCalls: Array<{ input: RequestInfo | URL; init?: RequestInit }> = [];
  const contentActions: ContentAction[] = [];
  const popupActionErrors = new Map<string, Error>();
  const popupActionNativeErrors = new Map<string, SerializedError[]>();
  const popupActionHandlers = new Map<
    string,
    (payload: Record<string, unknown>) => BridgePopupActionResult | Promise<BridgePopupActionResult>
  >();
  const popupActionResults = new Map<string, BridgePopupActionResult>();
  let helloProtocolVersion = 1;
  let helloSessionIds = ['safari-session-1'];
  let helloCount = 0;
  let attachedSessionId: string | undefined;
  let helloObserver: ((sessionId: string, helloCount: number) => void | Promise<void>) | undefined;
  let nativeBootstrap = bootstrap;
  let uiSnapshot = defaultUISnapshot();

  controls.setContentHandler((tabId, message) => {
    const tab = controls.tabs.get(tabId) ?? {};
    const pageState = pageStateFor(tab);
    if (!isContentRequest(message)) {
      throw new Error('Unexpected malformed content request.');
    }
    const request = message;
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
        throw new Error('Unexpected content request.');
    }
  });

  controls.setNativeHandler(async (message) => {
    const request = requireNativeRequest(message);
    switch (request.method) {
      case 'bridge.hello': {
        const sessionId = helloSessionIds[Math.min(helloCount, helloSessionIds.length - 1)] ?? 'safari-session-1';
        helloCount += 1;
        attachedSessionId = sessionId;
        await helloObserver?.(sessionId, helloCount);
        return nativeSuccess(request, {
          sessionId,
          protocolVersion: helloProtocolVersion,
          leaseExpiresAt: new Date(Date.now() + 60_000).toISOString(),
          pollAfterMillis: 200
        });
      }
      case 'bridge.popupAction': {
        const action = String(request.params.action);
        const payload = requireRecord(request.params.payload, 'popup action payload');
        popupCalls.push({ action, payload });
        const popupActionError = popupActionErrors.get(action);
        if (popupActionError) {
          throw popupActionError;
        }
        const nativeErrors = popupActionNativeErrors.get(action);
        const nativeError = nativeErrors?.shift();
        if (nativeError) {
          return {
            protocolVersion: 1,
            id: request.id,
            error: nativeError
          };
        }
        if (payload.safariSessionId !== attachedSessionId) {
          return {
            protocolVersion: 1,
            id: request.id,
            error: {
              code: 'daemon_rejected',
              message: 'The OpenBurnBar daemon rejected the Safari request.',
              retryable: false,
              details: { daemonCode: -32001 }
            }
          };
        }
        const popupActionHandler = popupActionHandlers.get(action);
        if (popupActionHandler) {
          return Promise.resolve(popupActionHandler(payload)).then((result) => nativeSuccess(request, result));
        }
        const overriddenResult = popupActionResults.get(action);
        if (overriddenResult) {
          return nativeSuccess(request, overriddenResult);
        }
        if (action === 'bootstrap') {
          return nativeSuccess(request, { accepted: true, output: nativeBootstrap });
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
            output: {
              runId: 'run-handoff',
              phase: 'waiting_on_companion',
              launched: true,
              running: true
            }
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

  let gatewayHandler: GatewayHandler = async () => {
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
  };
  const gatewayFetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    gatewayCalls.push({ input, ...(init === undefined ? {} : { init }) });
    return gatewayHandler(input, init);
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
    setPopupActionNativeErrors(action, errors) {
      popupActionNativeErrors.set(action, [...errors]);
    },
    setPopupActionHandler(action, handler) {
      if (handler) {
        popupActionHandlers.set(action, handler);
      } else {
        popupActionHandlers.delete(action);
      }
    },
    setPopupActionResult(action, result) {
      popupActionResults.set(action, result);
    },
    setGatewayHandler(handler) {
      gatewayHandler = handler;
    },
    setNativeBootstrap(value) {
      nativeBootstrap = value;
      uiSnapshot = {
        ...uiSnapshot,
        bootstrap: value
      };
    },
    setHelloProtocolVersion(protocolVersion) {
      helloProtocolVersion = protocolVersion;
    },
    setHelloSessionIds(sessionIds) {
      helloSessionIds = [...sessionIds];
      helloCount = 0;
    },
    helloCount() {
      return helloCount;
    },
    setHelloObserver(observer) {
      helloObserver = observer;
    },
    setUISnapshot(value) {
      uiSnapshot = value;
    }
  };
}

export function expectSuccess(response: PopupResponse): asserts response is Extract<PopupResponse, { ok: true }> {
  expect(response.ok, response.ok ? undefined : response.error.message).toBe(true);
}

export async function authorizeCloudScreenshots(harness: ControllerHarness): Promise<void> {
  const snapshot = harness.controller.currentSnapshot();
  const page = snapshot.page;
  if (!page) {
    throw new Error('Expected an active page.');
  }
  harness.controls.grantedOrigins.add('http://*/*');
  harness.controls.grantedOrigins.add('https://*/*');
  expectSuccess(
    await harness.controller.handlePopupRequest({
      type: 'popup.authorizePage',
      expectedStateVersion: snapshot.stateVersion,
      expectedTabId: page.tabId,
      expectedOrigin: new URL(page.url).origin,
      acknowledgeCloudScreenshots: true,
      websiteAccessGranted: true
    })
  );
}
