import type { BrowserAPI, BrowserTab } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';
import type { ContentRequest, ContentResponse } from '../shared/messages';
import {
  isRecord,
  isStringLiteral,
  type ActionVerification,
  type BoundingBox,
  type ContentAction,
  type ContentActionResult,
  type ContentPageState,
  type ExtractedPageContext,
  type PageContext,
  type PageState,
  type ScreenshotResult,
  type SnapshotNode,
  type ViewportInfo
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
  return isRecord(value) && typeof value.ok === 'boolean' && 'pageState' in value;
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new SafariExtensionError('content_schema_invalid', `${label} was malformed.`);
  }
  return value;
}

function requireString(record: Record<string, unknown>, key: string, label: string): string {
  const value = record[key];
  if (typeof value !== 'string') {
    throw new SafariExtensionError('content_schema_invalid', `${label}.${key} was malformed.`);
  }
  return value;
}

function requireFiniteNumber(record: Record<string, unknown>, key: string, label: string): number {
  const value = record[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new SafariExtensionError('content_schema_invalid', `${label}.${key} was malformed.`);
  }
  return value;
}

function requireBoolean(record: Record<string, unknown>, key: string, label: string): boolean {
  const value = record[key];
  if (typeof value !== 'boolean') {
    throw new SafariExtensionError('content_schema_invalid', `${label}.${key} was malformed.`);
  }
  return value;
}

function optionalBoolean(record: Record<string, unknown>, key: string, label: string): boolean | undefined {
  if (record[key] === undefined) {
    return undefined;
  }
  return requireBoolean(record, key, label);
}

function parseContentPageState(value: unknown, label: string): ContentPageState {
  const record = requireRecord(value, label);
  return {
    url: requireString(record, 'url', label),
    title: requireString(record, 'title', label),
    navigationEpoch: requireFiniteNumber(record, 'navigationEpoch', label),
    isTopFrame: requireBoolean(record, 'isTopFrame', label),
    capturedAt: requireString(record, 'capturedAt', label)
  };
}

function parseBoundingBox(value: unknown, label: string): BoundingBox | undefined {
  if (value === undefined) {
    return undefined;
  }
  const record = requireRecord(value, label);
  return {
    x: requireFiniteNumber(record, 'x', label),
    y: requireFiniteNumber(record, 'y', label),
    width: requireFiniteNumber(record, 'width', label),
    height: requireFiniteNumber(record, 'height', label)
  };
}

function optionalString(record: Record<string, unknown>, key: string, label: string): string | undefined {
  if (record[key] === undefined) {
    return undefined;
  }
  return requireString(record, key, label);
}

function parseSnapshotNode(value: unknown): SnapshotNode {
  const record = requireRecord(value, 'page context node');
  const box = parseBoundingBox(record.box, 'page context node.box');
  const description = optionalString(record, 'description', 'page context node');
  const nodeValue = optionalString(record, 'value', 'page context node');
  const checked = optionalBoolean(record, 'checked', 'page context node');
  const disabled = optionalBoolean(record, 'disabled', 'page context node');
  const expanded = optionalBoolean(record, 'expanded', 'page context node');
  const focused = optionalBoolean(record, 'focused', 'page context node');
  const selected = optionalBoolean(record, 'selected', 'page context node');
  const sensitive = optionalBoolean(record, 'sensitive', 'page context node');
  return {
    ref: requireString(record, 'ref', 'page context node'),
    role: requireString(record, 'role', 'page context node'),
    name: requireString(record, 'name', 'page context node'),
    selector: requireString(record, 'selector', 'page context node'),
    ...(box ? { box } : {}),
    ...(description === undefined ? {} : { description }),
    ...(nodeValue === undefined ? {} : { value: nodeValue }),
    ...(checked === undefined ? {} : { checked }),
    ...(disabled === undefined ? {} : { disabled }),
    ...(expanded === undefined ? {} : { expanded }),
    ...(focused === undefined ? {} : { focused }),
    ...(selected === undefined ? {} : { selected }),
    ...(sensitive === undefined ? {} : { sensitive })
  };
}

function parseViewport(value: unknown): ViewportInfo {
  const record = requireRecord(value, 'page context viewport');
  return {
    width: requireFiniteNumber(record, 'width', 'page context viewport'),
    height: requireFiniteNumber(record, 'height', 'page context viewport'),
    scrollX: requireFiniteNumber(record, 'scrollX', 'page context viewport'),
    scrollY: requireFiniteNumber(record, 'scrollY', 'page context viewport'),
    pageWidth: requireFiniteNumber(record, 'pageWidth', 'page context viewport'),
    pageHeight: requireFiniteNumber(record, 'pageHeight', 'page context viewport'),
    devicePixelRatio: requireFiniteNumber(record, 'devicePixelRatio', 'page context viewport'),
    visualViewportOffsetLeft: requireFiniteNumber(record, 'visualViewportOffsetLeft', 'page context viewport'),
    visualViewportOffsetTop: requireFiniteNumber(record, 'visualViewportOffsetTop', 'page context viewport'),
    visualViewportScale: requireFiniteNumber(record, 'visualViewportScale', 'page context viewport')
  };
}

function parseExtractedPageContext(value: unknown): ExtractedPageContext {
  const record = requireRecord(value, 'page context response');
  if (!Array.isArray(record.nodes)) {
    throw new SafariExtensionError('content_schema_invalid', 'page context response.nodes was malformed.');
  }
  return {
    pageState: parseContentPageState(record.pageState, 'page context response.pageState'),
    viewport: parseViewport(record.viewport),
    markdown: requireString(record, 'markdown', 'page context response'),
    snapshot: requireString(record, 'snapshot', 'page context response'),
    nodes: record.nodes.map(parseSnapshotNode),
    truncated: requireBoolean(record, 'truncated', 'page context response'),
    sensitive: requireBoolean(record, 'sensitive', 'page context response'),
    capturedAt: requireString(record, 'capturedAt', 'page context response')
  };
}

function parseActionVerification(value: unknown): ActionVerification {
  const record = requireRecord(value, 'page action verification');
  const activeElement = optionalString(record, 'activeElement', 'page action verification');
  let target: ActionVerification['target'];
  if (record.target !== undefined) {
    const targetRecord = requireRecord(record.target, 'page action verification.target');
    const ref = optionalString(targetRecord, 'ref', 'page action verification.target');
    const selector = optionalString(targetRecord, 'selector', 'page action verification.target');
    const box = parseBoundingBox(targetRecord.box, 'page action verification.target.box');
    const text = optionalString(targetRecord, 'text', 'page action verification.target');
    const targetValue = optionalString(targetRecord, 'value', 'page action verification.target');
    const checked = optionalBoolean(targetRecord, 'checked', 'page action verification.target');
    target = {
      ...(ref === undefined ? {} : { ref }),
      ...(selector === undefined ? {} : { selector }),
      ...(box === undefined ? {} : { box }),
      ...(text === undefined ? {} : { text }),
      ...(targetValue === undefined ? {} : { value: targetValue }),
      ...(checked === undefined ? {} : { checked })
    };
  }
  return {
    url: requireString(record, 'url', 'page action verification'),
    title: requireString(record, 'title', 'page action verification'),
    ...(activeElement === undefined ? {} : { activeElement }),
    ...(target === undefined ? {} : { target })
  };
}

function parseSerializedError(value: unknown): NonNullable<ContentActionResult['error']> {
  const record = requireRecord(value, 'page action response.error');
  return {
    code: requireString(record, 'code', 'page action response.error'),
    message: requireString(record, 'message', 'page action response.error'),
    retryable: requireBoolean(record, 'retryable', 'page action response.error'),
    ...(Object.hasOwn(record, 'details') ? { details: record.details } : {})
  };
}

function parseContentActionResult(value: unknown): ContentActionResult {
  const record = requireRecord(value, 'page action response');
  const error = record.error === undefined ? undefined : parseSerializedError(record.error);
  return {
    ok: requireBoolean(record, 'ok', 'page action response'),
    ...(Object.hasOwn(record, 'result') ? { result: record.result } : {}),
    ...(error === undefined ? {} : { error }),
    pageState: parseContentPageState(record.pageState, 'page action response.pageState'),
    verification: parseActionVerification(record.verification)
  };
}

function parseCapturePreparation(value: unknown): {
  token: string;
  originalScrollX: number;
  originalScrollY: number;
  pageWidth: number;
  pageHeight: number;
  viewportWidth: number;
  viewportHeight: number;
  devicePixelRatio: number;
} {
  const record = requireRecord(value, 'full-page capture preparation');
  return {
    token: requireString(record, 'token', 'full-page capture preparation'),
    originalScrollX: requireFiniteNumber(record, 'originalScrollX', 'full-page capture preparation'),
    originalScrollY: requireFiniteNumber(record, 'originalScrollY', 'full-page capture preparation'),
    pageWidth: requireFiniteNumber(record, 'pageWidth', 'full-page capture preparation'),
    pageHeight: requireFiniteNumber(record, 'pageHeight', 'full-page capture preparation'),
    viewportWidth: requireFiniteNumber(record, 'viewportWidth', 'full-page capture preparation'),
    viewportHeight: requireFiniteNumber(record, 'viewportHeight', 'full-page capture preparation'),
    devicePixelRatio: requireFiniteNumber(record, 'devicePixelRatio', 'full-page capture preparation')
  };
}

function parseScrollPosition(value: unknown): { scrollX: number; scrollY: number } {
  const record = requireRecord(value, 'full-page scroll response');
  return {
    scrollX: requireFiniteNumber(record, 'scrollX', 'full-page scroll response'),
    scrollY: requireFiniteNumber(record, 'scrollY', 'full-page scroll response')
  };
}

function parseScreenshotResult(value: unknown): ScreenshotResult {
  const record = requireRecord(value, 'image resize response');
  if (
    !isStringLiteral(record.mediaType, ['image/jpeg']) ||
    !isStringLiteral(record.source, ['viewport', 'full-page'])
  ) {
    throw new SafariExtensionError('content_schema_invalid', 'image resize response media fields were malformed.');
  }
  return {
    dataUrl: requireString(record, 'dataUrl', 'image resize response'),
    mediaType: record.mediaType,
    width: requireFiniteNumber(record, 'width', 'image resize response'),
    height: requireFiniteNumber(record, 'height', 'image resize response'),
    byteLength: requireFiniteNumber(record, 'byteLength', 'image resize response'),
    source: record.source,
    truncated: requireBoolean(record, 'truncated', 'image resize response')
  };
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
    const extracted = parseExtractedPageContext(response.result);
    return {
      ...extracted,
      pageState: nativePageState(tab, extracted.pageState)
    };
  }

  async execute(tab: BrowserTab, action: ContentAction): Promise<ContentActionResult & { pageState: PageState }> {
    const response = await this.send(tab, { type: 'content.execute', action });
    const result = parseContentActionResult(response.result);
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
    return parseCapturePreparation(response.result);
  }

  async scrollFullPage(tab: BrowserTab, token: string, y: number): Promise<{ scrollX: number; scrollY: number }> {
    const response = await this.send(tab, { type: 'content.capture.scroll', token, y });
    return parseScrollPosition(response.result);
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
    return parseScreenshotResult(response.result);
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
