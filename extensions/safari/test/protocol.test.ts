import {
  SAFARI_BRIDGE_PROTOCOL_VERSION,
  createNativeRequest,
  parseBridgeCompleteResult,
  parseBridgeHelloResult,
  parseBridgePollResult,
  parseBridgePopupActionResult,
  parseBridgeRuntimeState,
  parseNativeResponse,
  parseSafariBootstrapResponse,
  unwrapNativeResponse,
  validateNativeRequest,
  type PageState,
  type SafariTabSnapshot
} from '../src/shared/protocol';

const pageState: PageState = {
  tabId: 7,
  windowId: 2,
  url: 'https://example.com/',
  title: 'Example',
  navigationEpoch: 3,
  isActive: true,
  isTopFrame: true,
  capturedAt: '2026-08-10T12:00:00Z'
};

const tabSnapshot: SafariTabSnapshot = {
  tabId: 7,
  windowId: 2,
  url: 'https://example.com/',
  title: 'Example',
  isActive: true,
  isOwned: true,
  navigationEpoch: 3
};

describe('Safari native bridge protocol', () => {
  it('builds and validates the exact attach payload', () => {
    const request = createNativeRequest('hello-1', 'bridge.hello', {
      extensionInstanceId: 'instance-1',
      clientName: 'OpenBurnBar Safari WebExtension/1.0.34',
      supportedProtocolVersions: [1],
      activePage: pageState,
      capabilities: {
        captureVisibleTab: true,
        scripting: true,
        nativeMessaging: true,
        activeTabPermission: true,
        siteAccessGranted: false
      }
    });

    expect(request).toEqual({
      protocolVersion: 1,
      id: 'hello-1',
      method: 'bridge.hello',
      params: expect.objectContaining({
        extensionInstanceId: 'instance-1',
        activePage: pageState
      })
    });
    expect(() => validateNativeRequest(request)).not.toThrow();
  });

  it('rejects legacy, unknown, and incomplete attach fields', () => {
    expect(() =>
      validateNativeRequest({
        protocolVersion: 1,
        id: 'legacy',
        method: 'bridge.hello',
        params: {
          extensionVersion: '1.0.34',
          sessionId: 'legacy',
          capabilities: {}
        }
      })
    ).toThrow(/unknown field "extensionVersion"/u);

    expect(() =>
      validateNativeRequest({
        protocolVersion: 1,
        id: 'bad',
        method: 'bridge.hello',
        params: {
          extensionInstanceId: 'instance',
          clientName: 'client',
          supportedProtocolVersions: [],
          capabilities: {
            captureVisibleTab: true,
            scripting: true,
            nativeMessaging: true,
            activeTabPermission: true,
            siteAccessGranted: true
          }
        }
      })
    ).toThrow(/supportedProtocolVersions/u);
  });

  it('validates exact poll and completion payloads', () => {
    expect(() =>
      validateNativeRequest(
        createNativeRequest('poll-1', 'bridge.poll', {
          sessionId: 'session-1',
          activePage: pageState,
          knownTabs: [tabSnapshot]
        })
      )
    ).not.toThrow();

    expect(() =>
      validateNativeRequest(
        createNativeRequest('complete-1', 'bridge.complete', {
          sessionId: 'session-1',
          commandId: 'command-1',
          ok: false,
          error: 'Blocked by scope',
          pageState,
          tabs: [tabSnapshot]
        })
      )
    ).not.toThrow();

    expect(() =>
      createNativeRequest('complete-bad', 'bridge.complete', {
        sessionId: 'session-1',
        commandId: 'command-1',
        ok: true,
        tabs: []
      })
    ).toThrow(/pageState/u);
  });

  it('parses exact attach, poll, completion, bootstrap, and popup results', () => {
    expect(
      parseBridgeHelloResult({
        sessionId: 'session-1',
        protocolVersion: 1,
        leaseExpiresAt: '2026-08-10T12:10:00Z',
        pollAfterMillis: 200
      })
    ).toEqual({
      sessionId: 'session-1',
      protocolVersion: 1,
      leaseExpiresAt: '2026-08-10T12:10:00Z',
      pollAfterMillis: 200
    });

    const poll = parseBridgePollResult({
      command: {
        commandId: 'command-1',
        sessionId: 'session-1',
        action: 'click',
        arguments: { selector: '#buy' },
        targetTabId: 7,
        expectedNavigationEpoch: 3,
        issuedAt: '2026-08-10T12:00:00Z',
        expiresAt: '2026-08-10T12:00:30Z'
      },
      leaseExpiresAt: '2026-08-10T12:10:00Z',
      pollAfterMillis: 200
    });
    expect(poll.command?.action).toBe('click');
    expect(poll.command?.targetTabId).toBe(7);

    expect(
      parseBridgePollResult({
        command: null,
        leaseExpiresAt: '2026-08-10T12:10:00Z',
        pollAfterMillis: 500
      }).command
    ).toBeUndefined();
    expect(parseBridgeCompleteResult({ accepted: true })).toEqual({ accepted: true });

    expect(
      parseSafariBootstrapResponse({
        daemonVersion: '1.0.34',
        protocolVersion: 1,
        gatewayBaseURL: 'http://127.0.0.1:8317',
        gatewayBearerToken: 'loopback-only',
        gatewayAttributionCapability: 'ab'.repeat(32),
        gatewayAttributionExpiresAt: '2026-08-10T12:05:00.000Z',
        gatewayAvailable: true,
        computerUseAvailable: true,
        learningAvailable: true,
        learningOptedIn: false,
        tier: 'burnbar_pro'
      })
    ).toMatchObject({
      daemonVersion: '1.0.34',
      gatewayAvailable: true,
      gatewayAttributionCapability: 'ab'.repeat(32),
      gatewayAttributionExpiresAt: '2026-08-10T12:05:00.000Z',
      tier: 'burnbar_pro'
    });

    expect(
      parseBridgePopupActionResult({
        accepted: true,
        requestId: 'request-1',
        output: { answer: 'Hello' }
      })
    ).toMatchObject({ accepted: true, requestId: 'request-1' });
  });

  it('parses strict runtime projections and rejects malformed agents', () => {
    const state = parseBridgeRuntimeState({
      connection: 'connected',
      daemonVersion: '1.0.34',
      gatewayReady: true,
      killSwitchEnabled: false,
      membership: 'pro',
      activeRunId: 'run-1',
      agents: [
        {
          id: 'model-1',
          displayName: 'Model',
          providerName: 'Provider',
          kind: 'model',
          installed: true,
          cloud: true,
          supportsVision: true
        }
      ]
    });
    expect(state.agents).toHaveLength(1);
    expect(() =>
      parseBridgeRuntimeState({
        ...state,
        agents: [{ id: 'broken' }]
      })
    ).toThrow(/unknown field|must be/u);
  });

  it('binds responses to request IDs and exactly one result channel', () => {
    const response = parseNativeResponse(
      {
        protocolVersion: SAFARI_BRIDGE_PROTOCOL_VERSION,
        id: 'request-1',
        result: { ok: true }
      },
      'request-1'
    );
    expect(unwrapNativeResponse(response)).toEqual({ ok: true });

    expect(() =>
      parseNativeResponse(
        {
          protocolVersion: 1,
          id: 'wrong',
          result: {}
        },
        'request-1'
      )
    ).toThrow(/does not match/u);

    expect(() =>
      parseNativeResponse(
        {
          protocolVersion: 1,
          id: 'request-1',
          result: {},
          error: { code: 'bad', message: 'bad', retryable: false }
        },
        'request-1'
      )
    ).toThrow(/exactly one/u);

    expect(() =>
      unwrapNativeResponse({
        protocolVersion: 1,
        id: 'request-1',
        error: {
          code: 'denied',
          message: 'Denied',
          retryable: false
        }
      })
    ).toThrow(/Denied/u);
  });

  it('validates chunk transfer bounds and hashes', () => {
    expect(() =>
      createNativeRequest('chunk-1', 'bridge.chunk.begin', {
        transferId: 'transfer-1',
        originalMethod: 'bridge.popupAction',
        byteLength: 1024,
        chunkCount: 2,
        sha256: 'a'.repeat(64)
      })
    ).not.toThrow();

    expect(() =>
      createNativeRequest('chunk-bad', 'bridge.chunk.begin', {
        transferId: 'transfer-1',
        originalMethod: 'bridge.chunk.append',
        byteLength: 10,
        chunkCount: 1,
        sha256: 'bad'
      })
    ).toThrow(/originalMethod/u);
  });
});
