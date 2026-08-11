import type { BrowserAPI, BrowserTab } from '../shared/browser';
import { SafariExtensionError } from '../shared/errors';
import {
  SAFARI_SCREENSHOT_JPEG_QUALITY,
  SAFARI_SCREENSHOT_MAX_LONG_EDGE,
  type ScreenshotResult
} from '../shared/protocol';
import { ImagePipeline, type ScreenshotSegment } from './imagePipeline';
import type { SafariPageAdapter } from './pageAdapter';

const MAX_FULL_PAGE_CSS_HEIGHT = 12_000;
const MAX_FULL_PAGE_SEGMENTS = 12;

function requireActiveTab(tab: BrowserTab): void {
  if (typeof tab.id !== 'number' || tab.active !== true) {
    throw new SafariExtensionError('background_tab_blocked', 'OpenBurnBar only captures the active Safari tab.');
  }
}

export class SafariCaptureService {
  constructor(
    private readonly browserAPI: BrowserAPI,
    private readonly pageAdapter: SafariPageAdapter,
    private readonly imagePipeline = new ImagePipeline()
  ) {}

  async viewport(tab: BrowserTab): Promise<ScreenshotResult> {
    requireActiveTab(tab);
    const raw = await this.browserAPI.tabs.captureVisibleTab(tab.windowId, {
      format: 'jpeg',
      quality: SAFARI_SCREENSHOT_JPEG_QUALITY
    });
    try {
      return await this.imagePipeline.resize(
        raw,
        SAFARI_SCREENSHOT_MAX_LONG_EDGE,
        SAFARI_SCREENSHOT_JPEG_QUALITY,
        'viewport'
      );
    } catch {
      const resized = await this.pageAdapter.resizeImage(
        tab,
        raw,
        SAFARI_SCREENSHOT_MAX_LONG_EDGE,
        SAFARI_SCREENSHOT_JPEG_QUALITY
      );
      return {
        ...resized,
        source: 'viewport',
        truncated: false
      };
    }
  }

  async fullPage(tab: BrowserTab, optIn: boolean): Promise<ScreenshotResult> {
    requireActiveTab(tab);
    if (!optIn) {
      throw new SafariExtensionError(
        'full_page_capture_consent_required',
        'Full-page capture requires explicit approval for this action.'
      );
    }
    const token = crypto.randomUUID();
    const prepared = await this.pageAdapter.prepareFullPage(tab, token);
    const cappedHeight = Math.min(prepared.pageHeight, MAX_FULL_PAGE_CSS_HEIGHT);
    const segments: ScreenshotSegment[] = [];
    const seenScrollPositions = new Set<number>();
    let truncated = prepared.pageHeight > cappedHeight;

    try {
      for (
        let requestedY = 0;
        requestedY < cappedHeight && segments.length < MAX_FULL_PAGE_SEGMENTS;
        requestedY += Math.max(1, prepared.viewportHeight)
      ) {
        const actual = await this.pageAdapter.scrollFullPage(tab, token, requestedY);
        if (seenScrollPositions.has(actual.scrollY)) {
          break;
        }
        seenScrollPositions.add(actual.scrollY);
        const dataUrl = await this.browserAPI.tabs.captureVisibleTab(tab.windowId, {
          format: 'jpeg',
          quality: SAFARI_SCREENSHOT_JPEG_QUALITY
        });
        segments.push({ dataUrl, scrollY: actual.scrollY });
      }
      truncated ||=
        segments.length === MAX_FULL_PAGE_SEGMENTS && cappedHeight > prepared.viewportHeight * segments.length;
      return await this.imagePipeline.stitch(
        segments,
        cappedHeight,
        prepared.devicePixelRatio,
        SAFARI_SCREENSHOT_MAX_LONG_EDGE,
        SAFARI_SCREENSHOT_JPEG_QUALITY,
        truncated
      );
    } finally {
      await this.pageAdapter.restoreFullPage(tab, token).catch(() => {
        // The page may have navigated during capture. Never mask the primary result/error.
      });
    }
  }
}
