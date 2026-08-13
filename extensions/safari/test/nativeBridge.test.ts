import { base64ToBytes } from '../src/shared/binary';
import {
  BrowserNativeMessagingAdapter,
  NativeBridge,
  OPENBURNBAR_NATIVE_APPLICATION_ID,
  protocolVersion,
  type NativeMessagingAdapter
} from '../src/background/nativeBridge';
import type { NativeRequestEnvelope, PageState, SafariTabSnapshot } from '../src/shared/protocol';
import { requireNativeRequest, requireRecord } from './helpers/assertions';
import { createMockBrowser } from './helpers/mockBrowser';

const activePage: PageState = {
  tabId: 1,
  windowId: 10,
  url: 'https://example.com/',
  title: 'Example',
  navigationEpoch: 1,
  isActive: true,
  isTopFrame: true,
  capturedAt: '2026-08-10T12:00:00Z'
};

const knownTab: SafariTabSnapshot = {
  tabId: 1,
  windowId: 10,
  url: 'https://example.com/',
  title: 'Example',
  isActive: true,
  isOwned: true,
  navigationEpoch: 1
};

function responseFor(request: NativeRequestEnvelope, result: unknown): unknown {
  return {
    protocolVersion: 1,
    id: request.id,
    result
  };
}

describe('NativeBridge', () => {
  it('uses the centralized native application adapter', async () => {
    const { browser, controls } = createMockBrowser();
    controls.setNativeHandler((message) => {
      const request = requireRecord(message, 'native adapter payload');
      expect(request).toEqual({ hello: true });
      return { accepted: true };
    });
    const adapter = new BrowserNativeMessagingAdapter(browser);
    await adapter.send({ hello: true });
    expect(controls.nativeMessages).toEqual([{ hello: true }]);
    expect(OPENBURNBAR_NATIVE_APPLICATION_ID).toBe('com.openburnbar.app');
    expect(protocolVersion()).toBe(1);
  });

  it('attaches, records the daemon session, polls, completes, and sends popup aliases', async () => {
    const messages: NativeRequestEnvelope[] = [];
    const adapter: NativeMessagingAdapter = {
      async send(message) {
        const request = requireNativeRequest(message);
        messages.push(request);
        switch (request.method) {
          case 'bridge.hello':
            return responseFor(request, {
              sessionId: 'session-native',
              protocolVersion: 1,
              leaseExpiresAt: '2026-08-10T12:10:00Z',
              pollAfterMillis: 200
            });
          case 'bridge.poll':
            return responseFor(request, {
              command: null,
              leaseExpiresAt: '2026-08-10T12:10:00Z',
              pollAfterMillis: 250
            });
          case 'bridge.complete':
            return responseFor(request, { accepted: true });
          case 'bridge.popupAction':
            return responseFor(request, { accepted: true, output: { ready: true } });
          default:
            return responseFor(request, {});
        }
      }
    };
    const bridge = new NativeBridge({
      adapter,
      extensionVersion: '1.0.34',
      sessionId: 'extension-instance',
      idFactory: (() => {
        let index = 0;
        return () => `id-${++index}`;
      })()
    });

    const hello = await bridge.hello(activePage, {
      captureVisibleTab: true,
      scripting: true,
      nativeMessaging: true,
      activeTabPermission: true,
      siteAccessGranted: false
    });
    expect(hello.sessionId).toBe('session-native');
    expect(bridge.sessionId).toBe('session-native');
    expect(messages[0]?.params).toMatchObject({
      extensionInstanceId: 'extension-instance',
      activePage,
      supportedProtocolVersions: [1]
    });

    expect((await bridge.poll(activePage, [knownTab])).pollAfterMillis).toBe(250);
    await bridge.complete({
      commandId: 'command-1',
      ok: true,
      result: { clicked: true },
      pageState: activePage,
      tabs: [knownTab]
    });
    const popup = await bridge.popupAction('ui.snapshot', { runId: 'run-1' });
    expect(popup.accepted).toBe(true);
    expect(messages.at(-1)?.params).toMatchObject({
      sessionId: 'session-native',
      action: 'ui.snapshot',
      payload: {
        safariSessionId: 'session-native',
        runId: 'run-1'
      }
    });
  });

  it('chunks oversized UTF-8 requests with base64 and SHA-256 before committing', async () => {
    const messages: NativeRequestEnvelope[] = [];
    const adapter: NativeMessagingAdapter = {
      async send(message) {
        const request = requireNativeRequest(message);
        messages.push(request);
        if (request.method === 'bridge.chunk.commit') {
          return responseFor(request, { delivered: true });
        }
        return responseFor(request, { accepted: true });
      }
    };
    const ids = ['request', 'transfer', 'begin', 'append-1', 'append-2', 'append-3', 'commit'];
    const bridge = new NativeBridge({
      adapter,
      extensionVersion: '1.0.34',
      maxInlineBytes: 160,
      idFactory: () => ids.shift() ?? crypto.randomUUID()
    });
    const result = await bridge.request<{ delivered: boolean }>('bridge.popupAction', {
      sessionId: 'session',
      action: 'ask',
      payload: { prompt: '🔥'.repeat(180) }
    });
    expect(result).toEqual({ delivered: true });
    expect(messages[0]?.method).toBe('bridge.chunk.begin');
    expect(messages.at(-1)?.method).toBe('bridge.chunk.commit');
    const begin = messages[0]?.params ?? {};
    expect(begin.sha256).toMatch(/^[a-f0-9]{64}$/u);
    const appendMessages = messages.filter((message) => message.method === 'bridge.chunk.append');
    expect(appendMessages.length).toBe(Number(begin.chunkCount));
    const reconstructed = new Uint8Array(
      appendMessages.flatMap((message) => Array.from(base64ToBytes(String(message.params.data))))
    );
    expect(new TextDecoder().decode(reconstructed)).toContain('"method":"bridge.popupAction"');
    expect(new TextDecoder().decode(reconstructed)).toContain('🔥');
  });

  it('fails closed on transport errors, response mismatches, and rejected completion', async () => {
    const unreachable = new NativeBridge({
      adapter: {
        send: async () => {
          throw new Error('appex unavailable');
        }
      },
      extensionVersion: '1.0.34'
    });
    await expect(
      unreachable.hello(undefined, {
        captureVisibleTab: true,
        scripting: true,
        nativeMessaging: true,
        activeTabPermission: true,
        siteAccessGranted: false
      })
    ).rejects.toThrow(/could not reach/u);

    const mismatch = new NativeBridge({
      adapter: {
        send: async () => ({ protocolVersion: 1, id: 'wrong', result: {} })
      },
      extensionVersion: '1.0.34'
    });
    await expect(
      mismatch.hello(undefined, {
        captureVisibleTab: true,
        scripting: true,
        nativeMessaging: true,
        activeTabPermission: true,
        siteAccessGranted: false
      })
    ).rejects.toThrow(/does not match/u);

    const adapter: NativeMessagingAdapter = {
      async send(message) {
        const request = requireNativeRequest(message);
        return responseFor(
          request,
          request.method === 'bridge.hello'
            ? {
                sessionId: 'session',
                protocolVersion: 1,
                leaseExpiresAt: '2026-08-10T12:10:00Z',
                pollAfterMillis: 200
              }
            : { accepted: false }
        );
      }
    };
    const rejected = new NativeBridge({ adapter, extensionVersion: '1.0.34' });
    await rejected.hello(undefined, {
      captureVisibleTab: true,
      scripting: true,
      nativeMessaging: true,
      activeTabPermission: true,
      siteAccessGranted: false
    });
    await expect(
      rejected.complete({
        commandId: 'command',
        ok: false,
        error: 'failed',
        pageState: activePage,
        tabs: []
      })
    ).rejects.toThrow(/rejected/u);
  });
});
