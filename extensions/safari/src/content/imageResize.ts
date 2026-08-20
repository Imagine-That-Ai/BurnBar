import { dataUrlByteLength } from '../shared/binary';
import { SafariExtensionError } from '../shared/errors';
import type { ScreenshotResult } from '../shared/protocol';

export async function resizeImageInDocument(
  dataUrl: string,
  maxLongEdge: number,
  quality: number
): Promise<ScreenshotResult> {
  const image = new Image();
  image.decoding = 'async';
  image.src = dataUrl;
  await image.decode();
  const scale = Math.min(1, maxLongEdge / Math.max(image.naturalWidth, image.naturalHeight));
  const width = Math.max(1, Math.round(image.naturalWidth * scale));
  const height = Math.max(1, Math.round(image.naturalHeight * scale));
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d', { alpha: false });
  if (!context) {
    throw new SafariExtensionError('canvas_unavailable', 'Safari could not create a screenshot canvas.');
  }
  context.drawImage(image, 0, 0, width, height);
  const resized = canvas.toDataURL('image/jpeg', Math.min(Math.max(quality, 1), 100) / 100);
  return {
    dataUrl: resized,
    mediaType: 'image/jpeg',
    width,
    height,
    byteLength: dataUrlByteLength(resized),
    source: 'viewport',
    truncated: false
  };
}
