import { SafariCaptureService } from '../src/background/capture';
import { ImagePipeline } from '../src/background/imagePipeline';
import { SafariPageAdapter, nativePageState } from '../src/background/pageAdapter';
import { permissionPatternForURL, SitePermissionController } from '../src/background/permissions';
import { parsePreferences, SafariSessionStore } from '../src/background/sessionStore';
import { TabOwnershipRegistry } from '../src/background/tabOwnership';
import { isContentRequest, type ContentResponse } from '../src/shared/messages';
import type { ContentPageState } from '../src/shared/protocol';
import { createMockBrowser } from './helpers/mockBrowser';

const contentPageState: ContentPageState = {
  url: 'https://example.com/',
  title: 'Example',
  navigationEpoch: 2,
  isTopFrame: true,
  capturedAt: '2026-08-10T12:00:00Z'
};

describe('background permission, storage, ownership, page, and capture adapters', () => {
  it('normalizes site permission patterns and handles grant/revoke states', async () => {
    const { browser, controls } = createMockBrowser();
    const permissions = new SitePermissionController(browser);
    expect(permissionPatternForURL('https://example.com/path?q=1')).toBe('https://example.com/*');
    expect(permissionPatternForURL('http://127.0.0.1:42771/mixed')).toBe('http://127.0.0.1/*');
    expect(permissionPatternForURL('http://localhost:42771/mixed')).toBe('http://localhost/*');
    expect(permissionPatternForURL('https://example.com:8443/path')).toBe('https://example.com/*');
    expect(permissionPatternForURL('http://[::1]:42771/mixed')).toBe('http://[::1]/*');
    expect(() => permissionPatternForURL('file:///tmp/test')).toThrow(/HTTP and HTTPS/u);
    expect(() => permissionPatternForURL('not a url')).toThrow(/valid web URL/u);
    expect(await permissions.status('https://example.com/path')).toBe('prompt');
    expect(await permissions.request('https://example.com/path')).toBe('granted');
    expect(controls.grantedOrigins).toContain('https://example.com/*');
    expect(await permissions.status('https://example.com/other')).toBe('granted');
    expect(await permissions.revoke('https://example.com/path')).toBe(true);
    expect(await permissions.status('file:///tmp/test')).toBe('unsupported');

    controls.grantedOrigins.add('http://127.0.0.1/*');
    expect(await permissions.status('http://127.0.0.1:42771/mixed')).toBe('granted');
    expect(await permissions.revoke('http://127.0.0.1:42771/mixed')).toBe(true);
    expect(await permissions.status('http://127.0.0.1:42771/mixed')).toBe('prompt');
    expect(await permissions.request('http://127.0.0.1:42771/mixed')).toBe('granted');
    expect(controls.grantedOrigins).toContain('http://127.0.0.1/*');
  });

  it('round-trips preferences and sanitizes malformed storage', async () => {
    expect(parsePreferences(undefined)).toMatchObject({ mode: 'ask', onlyCurrentTab: true, sites: {} });
    expect(
      parsePreferences({
        selectedAgentId: 'model-1',
        mode: 'handoff',
        onlyCurrentTab: false,
        learningOptedIn: true,
        learningConsentSeen: true,
        sites: {
          'https://example.com': { allowed: true, sensitiveOverride: false },
          broken: { allowed: 'yes' }
        }
      })
    ).toEqual({
      selectedAgentId: 'model-1',
      mode: 'handoff',
      onlyCurrentTab: false,
      automaticallyTrustInvokedWebsites: false,
      learningOptedIn: true,
      learningConsentSeen: true,
      sites: {
        'https://example.com': { allowed: true, sensitiveOverride: false }
      }
    });
    const { browser } = createMockBrowser();
    const store = new SafariSessionStore(browser);
    const preferences = {
      mode: 'agentic' as const,
      onlyCurrentTab: true,
      automaticallyTrustInvokedWebsites: true,
      learningOptedIn: false,
      learningConsentSeen: true,
      sites: {
        'https://example.com': { allowed: true, sensitiveOverride: true }
      }
    };
    await store.save(preferences);
    expect(await store.load()).toEqual(preferences);
  });

  it('enforces active-tab ownership and releases sessions', () => {
    const registry = new TabOwnershipRegistry();
    const active = {
      id: 1,
      windowId: 10,
      active: true,
      url: 'https://example.com/'
    };
    const owned = registry.claimUserHanded(active, 'session-1', () => new Date('2026-08-10T12:00:00Z'));
    expect(owned).toMatchObject({ tabId: 1, source: 'user-handed', origin: 'https://example.com' });
    expect(registry.assertOwned(active, 'session-1')).toEqual(owned);
    expect(registry.isOwned(1, 'session-1')).toBe(true);
    expect(() => registry.assertOwned({ ...active, active: false }, 'session-1')).toThrow(/background/u);
    expect(() => registry.assertOwned(active, 'other')).toThrow(/only control/u);
    const opened = registry.registerAgentOpened({ id: 2, active: true, url: 'https://openai.com/' }, 'session-1');
    expect(opened.source).toBe('agent-opened');
    expect(registry.list()).toHaveLength(2);
    registry.release(2);
    expect(registry.isOwned(2)).toBe(false);
    registry.releaseSession('session-1');
    expect(registry.list()).toEqual([]);
    expect(() => registry.claimUserHanded({ active: true }, 'session')).toThrow(/identifier/u);
    expect(() => registry.claimUserHanded({ id: 3, active: false }, 'session')).toThrow(/must be active/u);
  });

  it('injects the content script on demand and enriches page/action state with tab identity', async () => {
    const { browser, controls } = createMockBrowser();
    let ready = false;
    controls.setContentHandler((_tabId, message) => {
      if (!isContentRequest(message)) {
        throw new Error('Unexpected malformed content request.');
      }
      const request = message;
      if (request.type === 'content.ping') {
        if (!ready) {
          throw new Error('not injected');
        }
        return { ok: true, result: { ready: true }, pageState: contentPageState } satisfies ContentResponse;
      }
      if (request.type === 'content.pageContext') {
        return {
          ok: true,
          result: {
            pageState: contentPageState,
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
            markdown: '# Example',
            snapshot: '[ref=obb-1]',
            nodes: [],
            truncated: false,
            sensitive: false,
            capturedAt: contentPageState.capturedAt
          },
          pageState: contentPageState
        } satisfies ContentResponse;
      }
      if (request.type === 'content.execute') {
        return {
          ok: true,
          result: {
            ok: true,
            result: { clicked: true },
            pageState: contentPageState,
            verification: { url: contentPageState.url, title: contentPageState.title }
          },
          pageState: contentPageState
        } satisfies ContentResponse;
      }
      if (request.type === 'content.image.resize') {
        return {
          ok: true,
          result: {
            dataUrl: 'data:image/jpeg;base64,anBlZw==',
            mediaType: 'image/jpeg',
            width: 100,
            height: 50,
            byteLength: 4,
            source: 'viewport',
            truncated: false
          },
          pageState: contentPageState
        } satisfies ContentResponse;
      }
      return { ok: true, result: { ready: true }, pageState: contentPageState } satisfies ContentResponse;
    });
    vi.spyOn(browser.scripting, 'executeScript').mockImplementation(async (options) => {
      ready = true;
      controls.scriptExecutions.push(options);
      return [{ result: true }];
    });
    const tab = await browser.tabs.get(1);
    const adapter = new SafariPageAdapter(browser);
    const context = await adapter.pageContext(tab);
    expect(context.pageState).toMatchObject({ tabId: 1, windowId: 10, navigationEpoch: 2 });
    expect(controls.scriptExecutions).toHaveLength(1);
    expect((await adapter.execute(tab, { kind: 'click', target: { selector: '#buy' } })).ok).toBe(true);
    expect(nativePageState(tab, contentPageState)).toMatchObject({
      tabId: 1,
      isActive: true,
      url: 'https://example.com/'
    });
    expect((await adapter.resizeImage(tab, 'raw', 1568, 82)).width).toBe(100);
    await adapter.abort(tab, 'stop');
  });

  it('captures viewport with page fallback and performs bounded full-page stitching', async () => {
    const { browser, controls } = createMockBrowser();
    controls.setContentHandler((_tabId, message) => {
      if (!isContentRequest(message)) {
        throw new Error('Unexpected malformed content request.');
      }
      const request = message;
      if (request.type === 'content.ping') {
        return { ok: true, result: { ready: true }, pageState: contentPageState };
      }
      if (request.type === 'content.image.resize') {
        return {
          ok: true,
          result: {
            dataUrl: 'data:image/jpeg;base64,anBlZw==',
            mediaType: 'image/jpeg',
            width: 1200,
            height: 675,
            byteLength: 4,
            source: 'viewport',
            truncated: false
          },
          pageState: contentPageState
        };
      }
      if (request.type === 'content.capture.prepare') {
        return {
          ok: true,
          result: {
            token: request.token,
            originalScrollX: 0,
            originalScrollY: 0,
            pageWidth: 1024,
            pageHeight: 1400,
            viewportWidth: 1024,
            viewportHeight: 700,
            devicePixelRatio: 1
          },
          pageState: contentPageState
        };
      }
      if (request.type === 'content.capture.scroll') {
        return {
          ok: true,
          result: { scrollX: 0, scrollY: request.y ?? 0 },
          pageState: contentPageState
        };
      }
      return { ok: true, result: { scrollX: 0, scrollY: 0 }, pageState: contentPageState };
    });
    const page = new SafariPageAdapter(browser);
    const pipeline = new ImagePipeline();
    vi.spyOn(pipeline, 'resize').mockRejectedValue(new Error('worker canvas unavailable'));
    vi.spyOn(pipeline, 'stitch').mockImplementation(async (_segments, _height, _dpr, _edge, _quality, truncated) => ({
      dataUrl: 'data:image/jpeg;base64,anBlZw==',
      mediaType: 'image/jpeg' as const,
      width: 800,
      height: 1094,
      byteLength: 4,
      source: 'full-page' as const,
      truncated
    }));
    const capture = new SafariCaptureService(browser, page, pipeline);
    const tab = await browser.tabs.get(1);
    expect((await capture.viewport(tab)).width).toBe(1200);
    await expect(capture.fullPage(tab, false)).rejects.toThrow(/explicit approval/u);
    const full = await capture.fullPage(tab, true);
    expect(full.source).toBe('full-page');
    expect(pipeline.stitch).toHaveBeenCalled();
    await expect(capture.viewport({ ...tab, active: false })).rejects.toThrow(/active/u);
  });
});
