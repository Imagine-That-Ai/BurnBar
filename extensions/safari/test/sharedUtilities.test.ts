import { activeTab, getBrowserAPI } from '../src/shared/browser';
import { base64ToBytes, bytesToBase64, dataUrlByteLength, sha256Hex } from '../src/shared/binary';
import { SafariExtensionError, errorMessage, serializeError } from '../src/shared/errors';
import {
  agentsForMode,
  isContentRequest,
  isPopupRequest,
  type ContentRequest,
  type PopupRequest
} from '../src/shared/messages';
import { createMockBrowser } from './helpers/mockBrowser';

describe('shared utilities', () => {
  it('serializes typed, DOM, ordinary, string, and unknown errors', () => {
    expect(
      serializeError(new SafariExtensionError('denied', 'Denied', { retryable: true, details: { scope: 'site' } }))
    ).toEqual({
      code: 'denied',
      message: 'Denied',
      retryable: true,
      details: { scope: 'site' }
    });
    expect(serializeError(new DOMException('Stopped', 'AbortError'))).toMatchObject({
      code: 'AbortError',
      retryable: true
    });
    expect(serializeError(new Error('Broken'))).toMatchObject({ message: 'Broken', retryable: false });
    expect(serializeError('bad')).toMatchObject({ message: 'bad' });
    expect(serializeError(new DOMException())).toMatchObject({
      message: 'The browser rejected the operation.',
      retryable: false
    });
    expect(serializeError(new DOMException('Wait', 'TimeoutError'))).toMatchObject({ retryable: true });
    expect(errorMessage(undefined, 'fallback')).toBe('An unknown error occurred.');
    expect(errorMessage(new Error(''), 'fallback')).toBe('fallback');
  });

  it('finds the active tab and validates browser availability', async () => {
    const { browser } = createMockBrowser();
    expect(getBrowserAPI(browser)).toBe(browser);
    expect((await activeTab(browser))?.id).toBe(1);
    expect(() => getBrowserAPI(null)).toThrow(/unavailable/u);
  });

  it('resolves the active tab from Safari’s current browser window', async () => {
    const { browser } = createMockBrowser();
    const queries: Record<string, unknown>[] = [];
    browser.tabs.query = async (query) => {
      queries.push(query);
      return query.currentWindow === true
        ? [
            {
              id: 2,
              windowId: 20,
              active: true,
              currentWindow: true,
              url: 'https://focused.example/',
              title: 'Focused'
            }
          ]
        : [];
    };

    expect((await activeTab(browser))?.id).toBe(2);
    expect(queries).toEqual([{ active: true, currentWindow: true }]);
  });

  it('fails closed when Safari has no active tab in its current browser window', async () => {
    const { browser } = createMockBrowser([]);
    expect(await activeTab(browser)).toBeUndefined();
  });

  it('filters models and CLIs by Safari mode', () => {
    const agents = [
      {
        id: 'vision',
        displayName: 'Vision',
        providerName: 'Cloud',
        kind: 'model' as const,
        installed: true,
        cloud: true,
        supportsVision: true
      },
      {
        id: 'text',
        displayName: 'Text',
        providerName: 'Cloud',
        kind: 'model' as const,
        installed: true,
        cloud: true,
        supportsVision: false
      },
      {
        id: 'codex',
        displayName: 'Codex',
        providerName: 'Local agent',
        kind: 'cli' as const,
        installed: true,
        cloud: false,
        supportsVision: false
      }
    ];
    expect(agentsForMode(agents, 'ask').map((agent) => agent.id)).toEqual(['vision']);
    expect(agentsForMode(agents, 'agentic').map((agent) => agent.id)).toEqual(['vision', 'text']);
    expect(agentsForMode(agents, 'handoff').map((agent) => agent.id)).toEqual(['codex']);
  });

  it('accepts only exact, runtime-safe popup request shapes', () => {
    const validRequests: PopupRequest[] = [
      { type: 'popup.bootstrap' },
      { type: 'popup.refresh' },
      { type: 'popup.setMode', mode: 'agentic' },
      { type: 'popup.selectAgent', agentId: 'codex' },
      { type: 'popup.ask', prompt: '' },
      { type: 'popup.startAgentic', prompt: 'Click the CTA' },
      { type: 'popup.handoff', prompt: 'Review this page' },
      { type: 'popup.approval', approvalId: 'approval-1', decision: 'allow_once' },
      { type: 'popup.abort', trigger: 'stop_button' },
      { type: 'popup.abort', trigger: 'popup_shortcut' },
      { type: 'popup.performanceSnapshot' },
      { type: 'popup.clearPerformance' },
      {
        type: 'popup.recordPerformance',
        metric: 'popup_bootstrap',
        durationMs: 42.5,
        outcome: 'success'
      },
      {
        type: 'popup.setTrust',
        patch: {
          globalKillSwitch: false,
          onlyCurrentTab: true,
          siteAllowed: true,
          sensitiveSiteOverride: false,
          cloudScreenshotAcknowledged: true
        }
      },
      { type: 'popup.requestSitePermission' },
      {
        type: 'popup.authorizePage',
        expectedStateVersion: 7,
        expectedTabId: 1,
        expectedOrigin: 'https://example.com',
        acknowledgeCloudScreenshots: true,
        websiteAccessGranted: true
      },
      { type: 'popup.setLearning', optedIn: true },
      { type: 'popup.teachCorrection', correction: 'Prefer annual totals.' },
      { type: 'popup.learningReview', itemId: 'proposal-1', decision: 'approve' }
    ];
    for (const request of validRequests) {
      expect(isPopupRequest(request)).toBe(true);
    }

    const invalidRequests: unknown[] = [
      null,
      [],
      { type: 'popup.unknown' },
      { type: 'popup.bootstrap', extra: true },
      { type: 'popup.setMode', mode: 'autonomous' },
      { type: 'popup.selectAgent', agentId: '   ' },
      { type: 'popup.ask', prompt: 42 },
      { type: 'popup.approval', approvalId: 'approval-1', decision: 'always' },
      { type: 'popup.abort' },
      { type: 'popup.abort', trigger: 'timer' },
      { type: 'popup.abort', trigger: 'stop_button', extra: true },
      {
        type: 'popup.authorizePage',
        expectedStateVersion: -1,
        expectedTabId: 1,
        expectedOrigin: 'https://example.com',
        acknowledgeCloudScreenshots: true,
        websiteAccessGranted: true
      },
      {
        type: 'popup.authorizePage',
        expectedStateVersion: 7,
        expectedTabId: 1,
        expectedOrigin: 'https://example.com',
        acknowledgeCloudScreenshots: true
      },
      {
        type: 'popup.recordPerformance',
        metric: 'ask_first_token',
        durationMs: 42.5,
        outcome: 'success'
      },
      {
        type: 'popup.recordPerformance',
        metric: 'popup_bootstrap',
        durationMs: Number.POSITIVE_INFINITY,
        outcome: 'success'
      },
      {
        type: 'popup.recordPerformance',
        metric: 'popup_bootstrap',
        durationMs: 42.5,
        outcome: 'partial'
      },
      { type: 'popup.setTrust', patch: {} },
      { type: 'popup.setTrust', patch: { siteAllowed: 'yes' } },
      { type: 'popup.setTrust', patch: { siteAllowed: true, arbitrary: true } },
      { type: 'popup.setLearning', optedIn: 'yes' },
      { type: 'popup.teachCorrection', correction: 'short' },
      { type: 'popup.teachCorrection', correction: 'x'.repeat(4 * 1024 + 1) },
      { type: 'popup.teachCorrection', correction: 'Prefer annual totals.', method: 'daemon.config.update' },
      { type: 'popup.learningReview', itemId: 'proposal-1', decision: 'archive' }
    ];
    for (const request of invalidRequests) {
      expect(isPopupRequest(request)).toBe(false);
    }
  });

  it('accepts only exact, runtime-safe content request and action shapes', () => {
    const validRequests: ContentRequest[] = [
      { type: 'content.ping' },
      { type: 'content.pageContext' },
      {
        type: 'content.execute',
        action: {
          kind: 'click',
          target: { ref: 'obb-1' },
          button: 'left',
          clickCount: 2
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'type',
          target: { selector: '#search' },
          text: 'OpenBurnBar',
          clear: true,
          submit: false,
          allowSensitive: false
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'type',
          text: 'Type into the focused field',
          clear: true,
          submit: false,
          allowSensitive: false
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'press_key',
          key: 'Enter',
          target: { point: { x: 12.5, y: 24 } },
          modifiers: ['Meta', 'Shift']
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'scroll',
          deltaX: 0,
          deltaY: 640,
          target: { selector: 'main' },
          behavior: 'smooth'
        }
      },
      { type: 'content.execute', action: { kind: 'hover', target: { selector: '.menu' } } },
      { type: 'content.execute', action: { kind: 'focus', target: { ref: 'obb-2' } } },
      {
        type: 'content.execute',
        action: {
          kind: 'select_option',
          target: { selector: 'select' },
          values: ['pro', 'Pro']
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'wait_for',
          selector: '[data-ready]',
          text: 'Ready',
          state: 'visible',
          timeoutMs: 5_000
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'run_javascript',
          source: 'return document.title;',
          approved: true,
          world: 'isolated',
          timeoutMs: 1_000
        }
      },
      {
        type: 'content.execute',
        action: {
          kind: 'extract',
          selector: '.price',
          attributes: ['data-sku'],
          limit: 25
        }
      },
      { type: 'content.capture.prepare', token: 'capture-1' },
      { type: 'content.capture.scroll', token: 'capture-1', y: 400 },
      { type: 'content.capture.restore', token: 'capture-1' },
      { type: 'content.abort', reason: 'User stopped the run.' },
      {
        type: 'content.image.resize',
        dataUrl: 'data:image/jpeg;base64,c291cmNl',
        maxLongEdge: 1_568,
        quality: 82
      }
    ];
    for (const request of validRequests) {
      expect(isContentRequest(request)).toBe(true);
    }

    const invalidRequests: unknown[] = [
      null,
      [],
      { type: 'content.unknown' },
      { type: 'content.ping', extra: true },
      { type: 'content.execute' },
      { type: 'content.execute', action: { kind: 'unknown' } },
      {
        type: 'content.execute',
        action: { kind: 'click', target: { selector: '#buy' }, unreviewed: true }
      },
      { type: 'content.execute', action: { kind: 'click', target: {} } },
      {
        type: 'content.execute',
        action: { kind: 'click', target: { selector: '#buy', arbitrary: true } }
      },
      {
        type: 'content.execute',
        action: { kind: 'click', target: { point: { x: 10, y: Number.NaN } } }
      },
      {
        type: 'content.execute',
        action: { kind: 'click', target: { ref: 'obb-1' }, button: 'primary' }
      },
      {
        type: 'content.execute',
        action: { kind: 'click', target: { ref: 'obb-1' }, clickCount: 3 }
      },
      {
        type: 'content.execute',
        action: { kind: 'type', target: { selector: '#search' }, text: 42 }
      },
      {
        type: 'content.execute',
        action: { kind: 'type', target: { selector: '#search' }, text: 'query', submit: 'yes' }
      },
      {
        type: 'content.execute',
        action: { kind: 'type', target: {}, text: 'query' }
      },
      { type: 'content.execute', action: { kind: 'press_key', key: '   ' } },
      {
        type: 'content.execute',
        action: { kind: 'press_key', key: 'Enter', modifiers: ['Command'] }
      },
      { type: 'content.execute', action: { kind: 'scroll', deltaY: Number.POSITIVE_INFINITY } },
      { type: 'content.execute', action: { kind: 'scroll', behavior: 'instant' } },
      { type: 'content.execute', action: { kind: 'hover', target: { selector: '' } } },
      {
        type: 'content.execute',
        action: { kind: 'select_option', target: { selector: 'select' }, values: ['pro', 1] }
      },
      { type: 'content.execute', action: { kind: 'wait_for', state: 'ready' } },
      { type: 'content.execute', action: { kind: 'wait_for', timeoutMs: 'soon' } },
      {
        type: 'content.execute',
        action: { kind: 'run_javascript', source: 'return 1;', approved: 'yes' }
      },
      {
        type: 'content.execute',
        action: { kind: 'run_javascript', source: 'return 1;', approved: true, world: 'main' }
      },
      {
        type: 'content.execute',
        action: { kind: 'extract', selector: '.price', attributes: ['data-sku', false] }
      },
      { type: 'content.execute', action: { kind: 'extract', selector: '.price', limit: Number.NaN } },
      { type: 'content.capture.prepare', token: '   ' },
      { type: 'content.capture.scroll', token: 'capture-1', y: '400' },
      { type: 'content.capture.restore', token: 'capture-1', extra: true },
      { type: 'content.abort', reason: '' },
      {
        type: 'content.image.resize',
        dataUrl: '',
        maxLongEdge: 1_568,
        quality: 82
      },
      {
        type: 'content.image.resize',
        dataUrl: 'data:image/jpeg;base64,c291cmNl',
        maxLongEdge: Number.POSITIVE_INFINITY,
        quality: 82
      },
      {
        type: 'content.image.resize',
        dataUrl: 'data:image/jpeg;base64,c291cmNl',
        maxLongEdge: 1_568,
        quality: '82'
      }
    ];
    for (const request of invalidRequests) {
      expect(isContentRequest(request)).toBe(false);
    }
  });

  it('round-trips binary data and calculates every data-URL encoding shape', async () => {
    const bytes = Uint8Array.from([0, 1, 2, 253, 254, 255]);
    expect(base64ToBytes(bytesToBase64(bytes))).toEqual(bytes);
    expect(dataUrlByteLength('plain text')).toBe(10);
    expect(dataUrlByteLength('data:text/plain;base64,YQ==')).toBe(1);
    expect(dataUrlByteLength('data:text/plain;base64,YWI=')).toBe(2);
    expect(dataUrlByteLength('data:text/plain;base64,YWJj')).toBe(3);
    expect(dataUrlByteLength('data:text/plain,hello%20world')).toBe(11);
    expect(await sha256Hex(new TextEncoder().encode('abc'))).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    );
  });
});
