import { FullPageCaptureCoordinator } from '../src/content/captureState';
import { resizeImageInDocument } from '../src/content/imageResize';
import { ImagePipeline, containedImageSize } from '../src/background/imagePipeline';
import { dataUrlByteLength } from '../src/shared/binary';

describe('capture and image processing', () => {
  it('prepares, scrolls, restores, and rejects stale full-page capture sessions', async () => {
    Object.defineProperty(document.documentElement, 'scrollWidth', { configurable: true, value: 1200 });
    Object.defineProperty(document.documentElement, 'scrollHeight', { configurable: true, value: 3000 });
    Object.defineProperty(document.documentElement, 'clientWidth', { configurable: true, value: 1024 });
    Object.defineProperty(document.documentElement, 'clientHeight', { configurable: true, value: 768 });
    window.scrollX = 12;
    window.scrollY = 48;
    document.documentElement.style.scrollBehavior = 'smooth';
    const coordinator = new FullPageCaptureCoordinator();
    const prepared = coordinator.prepare('capture-1');
    expect(prepared).toMatchObject({
      token: 'capture-1',
      originalScrollX: 12,
      originalScrollY: 48,
      pageHeight: 3000,
      viewportHeight: 768,
      devicePixelRatio: 2
    });
    expect(document.documentElement.style.scrollBehavior).toBe('auto');
    expect(await coordinator.scroll('capture-1', 900)).toEqual({ scrollX: 0, scrollY: 900 });
    expect(coordinator.restore('capture-1')).toEqual({ scrollX: 12, scrollY: 48 });
    expect(document.documentElement.style.scrollBehavior).toBe('smooth');
    await expect(coordinator.scroll('capture-1', 0)).rejects.toThrow(/missing or stale/u);
  });

  it('calculates contained dimensions and encoded byte sizes', () => {
    expect(containedImageSize(1920, 1080, 1568)).toEqual({ width: 1568, height: 882 });
    expect(containedImageSize(800, 600, 1568)).toEqual({ width: 800, height: 600 });
    expect(() => containedImageSize(0, 600, 1568)).toThrow(/positive/u);
    expect(dataUrlByteLength('data:image/jpeg;base64,anBlZw==')).toBe(4);
    expect(dataUrlByteLength('data:text/plain,hello%20world')).toBe(11);
    expect(dataUrlByteLength('plain')).toBe(5);
  });

  it('resizes and stitches screenshots without allocating a raw full-page canvas', async () => {
    const drawImage = vi.fn();
    const convertToBlob = vi.fn(async () => new Blob(['jpeg'], { type: 'image/jpeg' }));
    class FakeOffscreenCanvas {
      constructor(
        readonly width: number,
        readonly height: number
      ) {}

      getContext(): { drawImage: typeof drawImage } {
        return { drawImage };
      }

      convertToBlob = convertToBlob;
    }
    const closed = vi.fn();
    vi.stubGlobal('OffscreenCanvas', FakeOffscreenCanvas);
    vi.stubGlobal(
      'createImageBitmap',
      vi.fn(async () => ({ width: 1920, height: 1080, close: closed }))
    );
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({
        blob: async () => new Blob(['source'], { type: 'image/jpeg' })
      }))
    );

    const pipeline = new ImagePipeline();
    const resized = await pipeline.resize('data:image/jpeg;base64,c291cmNl', 1568, 82);
    expect(resized).toMatchObject({
      width: 1568,
      height: 882,
      mediaType: 'image/jpeg',
      source: 'viewport',
      truncated: false
    });
    expect(drawImage).toHaveBeenCalled();
    expect(closed).toHaveBeenCalled();

    drawImage.mockClear();
    const stitched = await pipeline.stitch(
      [
        { dataUrl: 'data:image/jpeg;base64,one', scrollY: 0 },
        { dataUrl: 'data:image/jpeg;base64,two', scrollY: 540 }
      ],
      1080,
      2,
      1568,
      82,
      true
    );
    expect(stitched).toMatchObject({
      width: 1394,
      height: 1568,
      source: 'full-page',
      truncated: true
    });
    expect(drawImage).toHaveBeenCalledTimes(2);

    await expect(pipeline.stitch([], 1000, 2, 1568, 82, false)).rejects.toThrow(/no viewport/u);
  });

  it('falls back to a document canvas resize path', async () => {
    class FakeImage {
      decoding = '';
      src = '';
      naturalWidth = 2000;
      naturalHeight = 1000;

      async decode(): Promise<void> {}
    }
    const drawImage = vi.fn();
    const toDataURL = vi.fn(() => 'data:image/jpeg;base64,anBlZw==');
    vi.stubGlobal('Image', FakeImage);
    const createElement = document.createElement.bind(document);
    vi.spyOn(document, 'createElement').mockImplementation((tagName: string, options?: ElementCreationOptions) => {
      if (tagName === 'canvas') {
        const canvas = createElement('canvas');
        Object.defineProperties(canvas, {
          getContext: {
            configurable: true,
            value: vi.fn(() => ({ drawImage }))
          },
          toDataURL: {
            configurable: true,
            value: toDataURL
          }
        });
        return canvas;
      }
      return createElement(tagName, options);
    });

    const result = await resizeImageInDocument('data:image/jpeg;base64,c291cmNl', 1568, 82);
    expect(result).toMatchObject({ width: 1568, height: 784, byteLength: 4 });
    expect(toDataURL).toHaveBeenCalledWith('image/jpeg', 0.82);
  });
});
