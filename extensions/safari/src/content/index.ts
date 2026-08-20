import { ContentActionExecutor } from './act';
import { FullPageCaptureCoordinator } from './captureState';
import { extractPageContext } from './extract';
import { resizeImageInDocument } from './imageResize';
import { ensurePageWorldRunner } from './pageWorldBridge';
import { getContentBrowserAPI } from '../shared/browser';
import { serializeError } from '../shared/errors';
import { isContentRequest, type ContentRequest, type ContentResponse } from '../shared/messages';
import { currentPageState } from './verification';

const browserAPI = getContentBrowserAPI();
const executor = new ContentActionExecutor();
const capture = new FullPageCaptureCoordinator();

async function handleRequest(message: ContentRequest): Promise<ContentResponse> {
  try {
    const pageState = currentPageState();
    switch (message.type) {
      case 'content.ping':
        return { ok: true, result: { ready: true }, pageState };
      case 'content.pageContext': {
        const result = extractPageContext();
        return { ok: true, result, pageState: result.pageState };
      }
      case 'content.execute': {
        const result = await executor.execute(message.action, (path) => browserAPI.runtime.getURL(path));
        return { ok: true, result, pageState: result.pageState };
      }
      case 'content.abort':
        executor.abort(message.reason);
        return { ok: true, result: { ready: true }, pageState };
      case 'content.capture.prepare': {
        const result = capture.prepare(message.token);
        return { ok: true, result, pageState };
      }
      case 'content.capture.scroll': {
        const result = await capture.scroll(message.token, message.y);
        return { ok: true, result, pageState: currentPageState() };
      }
      case 'content.capture.restore': {
        const result = capture.restore(message.token);
        return { ok: true, result, pageState: currentPageState() };
      }
      case 'content.image.resize': {
        const result = await resizeImageInDocument(message.dataUrl, message.maxLongEdge, message.quality);
        return { ok: true, result, pageState };
      }
    }
  } catch (error) {
    return {
      ok: false,
      error: serializeError(error, 'content_request_failed'),
      pageState: currentPageState()
    };
  }
}

browserAPI.runtime.onMessage.addListener((message) => {
  if (!isContentRequest(message)) {
    return undefined;
  }
  return handleRequest(message);
});

void ensurePageWorldRunner((path) => browserAPI.runtime.getURL(path)).catch(() => {
  // Page-world execution is an approved fallback. Isolated-world extraction/actions remain available.
});
