import type { PetAtlasDefinition, PetAtlasState } from './petCatalog.js';

export type PetAtlasFrame = {
  x: number;
  y: number;
  width: number;
  height: number;
};

let activePetAtlasRuntimeStop: (() => void) | null = null;
let activePetAtlasSetState: ((requestedState: string) => void) | null = null;
let requestedPetAtlasState: string | null = null;

export function resolvePetAtlasState(
  atlas: PetAtlasDefinition,
  requestedState: string
): { name: string; descriptor: PetAtlasState } {
  const exact = atlas.states[requestedState];
  if (exact) return { name: requestedState, descriptor: exact };
  const aliases: Record<string, string[]> = {
    wander: ['travel', 'scuttle', 'waddle', 'bounce', 'walk'],
    drag: ['travel', 'scuttle', 'waddle', 'bounce', 'walk'],
    listen: ['listen', 'alert', 'idle'],
    think: ['work', 'pinch_sweep', 'claw_scoop', 'peck_sweep', 'hand_scoop', 'idle'],
    speak: ['speak', 'honk', 'wave', 'snip', 'work', 'pinch_sweep', 'hand_scoop', 'idle'],
    react: ['cheer', 'alert', 'idle']
  };
  for (const candidate of aliases[requestedState] ?? []) {
    const descriptor = atlas.states[candidate];
    if (descriptor) return { name: candidate, descriptor };
  }
  const fallbackName = atlas.defaultState in atlas.states
    ? atlas.defaultState
    : atlas.states.idle
      ? 'idle'
      : Object.keys(atlas.states)[0];
  if (!fallbackName || !atlas.states[fallbackName]) throw new Error('Pet atlas has no renderable states.');
  return { name: fallbackName, descriptor: atlas.states[fallbackName] };
}

/**
 * Change the active atlas animation without replacing the decoded asset. The
 * requested logical state is retained so a runtime that mounts later (initial
 * atlas load, or switching pets mid-response) starts from the current
 * interaction state instead of silently falling back to its default idle.
 */
export function setPetAtlasState(requestedState: string): void {
  requestedPetAtlasState = requestedState;
  activePetAtlasSetState?.(requestedState);
}

export function petAtlasFrameRect(
  atlas: PetAtlasDefinition,
  requestedState: string,
  frame: number
): PetAtlasFrame {
  const { descriptor } = resolvePetAtlasState(atlas, requestedState);
  const clampedFrame = Math.max(0, Math.min(Math.trunc(frame), Math.max(descriptor.frames - 1, 0)));
  return {
    x: clampedFrame * atlas.cell.w,
    y: descriptor.row * atlas.cell.h,
    width: atlas.cell.w,
    height: atlas.cell.h
  };
}

function loadImage(source: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error('Pet atlas image could not be decoded.'));
    image.src = source;
  });
}

export async function mountPetAtlasRuntime(
  host: HTMLElement,
  asset: string | ArrayBuffer,
  atlas: PetAtlasDefinition,
  mimeType = 'image/webp'
): Promise<void> {
  stopPetAtlasRuntime();
  host.replaceChildren();
  const canvas = document.createElement('canvas');
  canvas.className = 'pet-canvas pet-atlas-canvas';
  canvas.setAttribute('aria-hidden', 'true');
  const caption = document.createElement('p');
  caption.className = 'muted pet-runtime-caption';
  host.append(canvas, caption);

  let objectURL: string | null = null;
  try {
    let source: string;
    if (typeof asset === 'string') {
      source = asset;
    } else {
      objectURL = URL.createObjectURL(new Blob([asset], { type: mimeType }));
      source = objectURL;
    }
    const image = await loadImage(source);
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Pet atlas canvas is unavailable.');
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    let state = resolvePetAtlasState(atlas, requestedPetAtlasState ?? atlas.defaultState);
    let frameCount = Math.max(1, state.descriptor.frames);
    let frame = 0;
    let lastFrameAt = 0;
    let animationFrame = 0;
    let stopped = false;
    let rendered = false;

    const draw = (timestamp: number): void => {
      if (stopped) return;
      const displayWidth = Math.max(1, Math.round(canvas.clientWidth || atlas.cell.w));
      const displayHeight = Math.max(1, Math.round(canvas.clientHeight || atlas.cell.h));
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      const backingWidth = Math.round(displayWidth * dpr);
      const backingHeight = Math.round(displayHeight * dpr);
      // Only reallocate the backing store when the display size actually
      // changed, and only redraw when a new frame is due, so a 60 Hz display
      // does not repaint a 6-12 fps atlas on every refresh.
      let needsRedraw = !rendered || canvas.width !== backingWidth || canvas.height !== backingHeight;
      if (canvas.width !== backingWidth || canvas.height !== backingHeight) {
        canvas.width = backingWidth;
        canvas.height = backingHeight;
      }
      // Loop rows animate indefinitely; one-shot rows advance through their
      // frames once and then hold the final frame.
      const animating = !reducedMotion && (state.descriptor.loop || frame < frameCount - 1);
      if (animating) {
        const frameDuration = 1000 / Math.max(1, state.descriptor.fps);
        if (!lastFrameAt) {
          lastFrameAt = timestamp;
        } else if (timestamp - lastFrameAt >= frameDuration) {
          frame = frame < frameCount - 1 ? frame + 1 : 0;
          lastFrameAt = timestamp;
          needsRedraw = true;
        }
      }
      if (needsRedraw) {
        const rect = petAtlasFrameRect(atlas, state.name, frame);
        // Aspect-fit the source frame inside the canvas so shared atlas pets
        // keep the macOS renderer's geometry instead of stretching to fill
        // the 16:7 viewport.
        const scale = Math.min(canvas.width / rect.width, canvas.height / rect.height);
        const drawWidth = Math.max(1, Math.round(rect.width * scale));
        const drawHeight = Math.max(1, Math.round(rect.height * scale));
        const drawX = Math.round((canvas.width - drawWidth) / 2);
        const drawY = Math.round((canvas.height - drawHeight) / 2);
        context.clearRect(0, 0, canvas.width, canvas.height);
        context.imageSmoothingEnabled = false;
        context.drawImage(image, rect.x, rect.y, rect.width, rect.height, drawX, drawY, drawWidth, drawHeight);
        rendered = true;
      }
      if (animating) animationFrame = window.requestAnimationFrame(draw);
    };

    const describeState = (): void => {
      caption.textContent = `2D atlas loaded ${state.name} animation; ${frameCount} frames at ${state.descriptor.fps} fps.`;
    };

    activePetAtlasSetState = (requestedState: string) => {
      if (stopped) return;
      state = resolvePetAtlasState(atlas, requestedState);
      frameCount = Math.max(1, state.descriptor.frames);
      frame = 0;
      // Force a repaint so the new state's first frame shows immediately even
      // when the canvas backing store is unchanged.
      rendered = false;
      lastFrameAt = performance.now();
      if (animationFrame) window.cancelAnimationFrame(animationFrame);
      animationFrame = 0;
      describeState();
      draw(lastFrameAt);
    };
    activePetAtlasRuntimeStop = () => {
      stopped = true;
      if (animationFrame) window.cancelAnimationFrame(animationFrame);
      if (objectURL) URL.revokeObjectURL(objectURL);
      activePetAtlasSetState = null;
      activePetAtlasRuntimeStop = null;
    };
    draw(0);
    describeState();
  } catch (error) {
    if (objectURL) URL.revokeObjectURL(objectURL);
    throw error;
  }
}

export function stopPetAtlasRuntime(): void {
  activePetAtlasRuntimeStop?.();
  activePetAtlasSetState = null;
  activePetAtlasRuntimeStop = null;
}
