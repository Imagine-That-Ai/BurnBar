import type { BrowserAPI, BrowserTab } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';
import type { ContentRequest, ContentResponse } from '../shared/messages';
import type {
  ContentAction,
  ContentActionResult,
  ContentPageState,
  ExtractedPageContext,
  PageContext,
  PageState,
  ScreenshotResult
} from '../shared/protocol';

function tabId(tab: BrowserTab): number {
  if (typeof tab.id !== 'number') {
    throw new SafariExtensionError('tab_id_missing', 'Safari did not provide an active tab identifier.');
  }
  return tab.id;
}

export function nativePageState(tab: BrowserTab, state: ContentPageState): PageState {
  return {
    tabId: tabId(tab),
    ...(typeof tab.windowId === 'number' ? { windowId: tab.windowId } : {}),
    url: state.url,
    title: state.title,
    navigationEpoch: state.navigationEpoch,
    isActive: tab.active === true,
    isTopFrame: state.isTopFrame,
    capturedAt: state.capturedAt
  };
}

function isContentResponse(value: unknown): value is ContentResponse {
  return (
    typeof value === 'object' &&
    value !== null &&
    'ok' in value &&
    typeof (value as { ok?: unknown }).ok === 'boolean' &&
    'pageState' in value
  );
}

export class SafariPageAdapter {
  constructor(private readonly browserAPI: BrowserAPI) {}

  async ensureInjected(tab: BrowserTab): Promise<void> {
    const id = tabId(tab);
    try {
      const ping = await this.browserAPI.tabs.sendMessage(id, { type: 'content.ping' } satisfies ContentRequest);
      if (isContentResponse(ping) && ping.ok) {
        return;
      }
    } catch {
      // The content script is injected on demand below.
    }

    try {
      await this.browserAPI.scripting.executeScript({
        target: { tabId: id },
        files: ['content.js']
      });
      const ping = await this.browserAPI.tabs.sendMessage(id, { type: 'content.ping' } satisfies ContentRequest);
      if (!isContentResponse(ping) || !ping.ok) {
        throw new SafariExtensionError('content_script_unavailable', 'The page did not accept the content script.');
      }
    } catch (error) {
      throw new SafariExtensionError('site_access_required', 'Allow OpenBurnBar on this website, then try again.', {
        retryable: true,
        details: error
      });
    }
  }

  async pageContext(tab: BrowserTab): Promise<PageContext> {
    const response = await this.send(tab, { type: 'content.pageContext' });
    const extracted = response.result as ExtractedPageContext;
    if (
      !extracted ||
      typeof extracted !== 'object' ||
      typeof extracted.markdown !== 'string' ||
      typeof extracted.snapshot !== 'string' ||
      !Array.isArray(extracted.nodes)
    ) {
      throw new SafariExtensionError('content_schema_invalid', 'The page context response was malformed.');
    }
    return {
      ...extracted,
      pageState: nativePageState(tab, extracted.pageState)
    };
  }

  async execute(tab: BrowserTab, action: ContentAction): Promise<ContentActionResult & { pageState: PageState }> {
    const response = await this.send(tab, { type: 'content.execute', action });
    const result = response.result as ContentActionResult;
    if (!result || typeof result !== 'object' || typeof result.ok !== 'boolean') {
      throw new SafariExtensionError('content_schema_invalid', 'The page action response was malformed.');
    }
    return {
      ...result,
      pageState: nativePageState(tab, result.pageState)
    };
  }

  async abort(tab: BrowserTab, reason: string): Promise<void> {
    await this.send(tab, { type: 'content.abort', reason });
  }

  async prepareFullPage(
    tab: BrowserTab,
    token: string
  ): Promise<{
    token: string;
    originalScrollX: number;
    originalScrollY: number;
    pageWidth: number;
    pageHeight: number;
    viewportWidth: number;
    viewportHeight: number;
    devicePixelRatio: number;
  }> {
    const response = await this.send(tab, { type: 'content.capture.prepare', token });
    return response.result as {
      token: string;
      originalScrollX: number;
      originalScrollY: number;
      pageWidth: number;
      pageHeight: number;
      viewportWidth: number;
      viewportHeight: number;
      devicePixelRatio: number;
    };
  }

  async scrollFullPage(tab: BrowserTab, token: string, y: number): Promise<{ scrollX: number; scrollY: number }> {
    const response = await this.send(tab, { type: 'content.capture.scroll', token, y });
    return response.result as { scrollX: number; scrollY: number };
  }

  async restoreFullPage(tab: BrowserTab, token: string): Promise<void> {
    await this.send(tab, { type: 'content.capture.restore', token });
  }

  async resizeImage(tab: BrowserTab, dataUrl: string, maxLongEdge: number, quality: number): Promise<ScreenshotResult> {
    const response = await this.send(tab, {
      type: 'content.image.resize',
      dataUrl,
      maxLongEdge,
      quality
    });
    return response.result as ScreenshotResult;
  }

  private async send(tab: BrowserTab, request: ContentRequest): Promise<Extract<ContentResponse, { ok: true }>> {
    await this.ensureInjected(tab);
    const response = await this.browserAPI.tabs.sendMessage(tabId(tab), request);
    if (!isContentResponse(response)) {
      throw new SafariExtensionError('content_schema_invalid', 'Safari returned a malformed content-script response.');
    }
    if (!response.ok) {
      throw new SafariExtensionError(response.error.code, response.error.message, {
        retryable: response.error.retryable,
        ...(response.error.details === undefined ? {} : { details: response.error.details })
      });
    }
    return response;
  }
}
