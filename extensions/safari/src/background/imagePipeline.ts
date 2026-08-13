import { bytesToBase64, dataUrlByteLength } from '../shared/binary';
import { SafariExtensionError } from '../shared/errors';
import type { ScreenshotResult } from '../shared/protocol';

interface ImageDimensions {
  width: number;
  height: number;
}

export interface ScreenshotSegment {
  dataUrl: string;
  scrollY: number;
}

export function containedImageSize(width: number, height: number, maxLongEdge: number): ImageDimensions {
  if (
    !Number.isFinite(width) ||
    !Number.isFinite(height) ||
    !Number.isFinite(maxLongEdge) ||
    width <= 0 ||
    height <= 0 ||
    maxLongEdge <= 0
  ) {
    throw new SafariExtensionError('image_dimensions_invalid', 'Screenshot dimensions must be positive.');
  }
  const scale = Math.min(1, maxLongEdge / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  };
}

async function blobToDataUrl(blob: Blob): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  return `data:${blob.type || 'image/jpeg'};base64,${bytesToBase64(bytes)}`;
}

async function bitmapForDataUrl(dataUrl: string): Promise<ImageBitmap> {
  if (typeof createImageBitmap !== 'function') {
    throw new SafariExtensionError('offscreen_image_unavailable', 'Safari cannot decode screenshots in this context.');
  }
  const response = await fetch(dataUrl);
  return createImageBitmap(await response.blob());
}

function offscreenCanvas(width: number, height: number): OffscreenCanvas {
  if (typeof OffscreenCanvas === 'undefined') {
    throw new SafariExtensionError(
      'offscreen_canvas_unavailable',
      'This Safari version cannot process screenshots in its background worker.'
    );
  }
  return new OffscreenCanvas(width, height);
}

export class ImagePipeline {
  async resize(
    dataUrl: string,
    maxLongEdge: number,
    quality: number,
    source: ScreenshotResult['source'] = 'viewport'
  ): Promise<ScreenshotResult> {
    const bitmap = await bitmapForDataUrl(dataUrl);
    try {
      const size = containedImageSize(bitmap.width, bitmap.height, maxLongEdge);
      const canvas = offscreenCanvas(size.width, size.height);
      const context = canvas.getContext('2d', { alpha: false });
      if (!context) {
        throw new SafariExtensionError('canvas_unavailable', 'Safari could not create a screenshot canvas.');
      }
      context.drawImage(bitmap, 0, 0, size.width, size.height);
      const blob = await canvas.convertToBlob({
        type: 'image/jpeg',
        quality: Math.min(Math.max(quality, 1), 100) / 100
      });
      const resized = await blobToDataUrl(blob);
      return {
        dataUrl: resized,
        mediaType: 'image/jpeg',
        width: size.width,
        height: size.height,
        byteLength: dataUrlByteLength(resized),
        source,
        truncated: false
      };
    } finally {
      bitmap.close();
    }
  }

  async stitch(
    segments: ScreenshotSegment[],
    pageHeightCss: number,
    devicePixelRatio: number,
    maxLongEdge: number,
    quality: number,
    truncated: boolean
  ): Promise<ScreenshotResult> {
    if (segments.length === 0) {
      throw new SafariExtensionError('capture_empty', 'Full-page capture returned no viewport segments.');
    }
    const bitmaps = await Promise.all(segments.map((segment) => bitmapForDataUrl(segment.dataUrl)));
    try {
      const first = bitmaps[0];
      if (!first) {
        throw new SafariExtensionError('capture_empty', 'Full-page capture returned no decoded image.');
      }
      const rawWidth = first.width;
      const rawHeight = Math.max(1, Math.round(pageHeightCss * Math.max(0.1, devicePixelRatio)));
      const size = containedImageSize(rawWidth, rawHeight, maxLongEdge);
      const outputCanvas = offscreenCanvas(size.width, size.height);
      const outputContext = outputCanvas.getContext('2d', { alpha: false });
      if (!outputContext) {
        throw new SafariExtensionError('canvas_unavailable', 'Safari could not create a resized full-page canvas.');
      }
      const scaleX = size.width / rawWidth;
      const scaleY = size.height / rawHeight;
      for (let index = 0; index < segments.length; index += 1) {
        const segment = segments[index];
        const bitmap = bitmaps[index];
        if (!segment || !bitmap) {
          continue;
        }
        const y = Math.round(segment.scrollY * devicePixelRatio);
        const remaining = rawHeight - y;
        if (remaining <= 0) {
          continue;
        }
        const drawHeight = Math.min(bitmap.height, remaining);
        outputContext.drawImage(
          bitmap,
          0,
          0,
          bitmap.width,
          drawHeight,
          0,
          Math.round(y * scaleY),
          Math.round(rawWidth * scaleX),
          Math.ceil(drawHeight * scaleY)
        );
      }

      const blob = await outputCanvas.convertToBlob({
        type: 'image/jpeg',
        quality: Math.min(Math.max(quality, 1), 100) / 100
      });
      const dataUrl = await blobToDataUrl(blob);
      return {
        dataUrl,
        mediaType: 'image/jpeg',
        width: size.width,
        height: size.height,
        byteLength: dataUrlByteLength(dataUrl),
        source: 'full-page',
        truncated
      };
    } finally {
      for (const bitmap of bitmaps) {
        bitmap.close();
      }
    }
  }
}
