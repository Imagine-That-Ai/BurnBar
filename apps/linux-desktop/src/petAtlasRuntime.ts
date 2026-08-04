import type { PetAtlasDefinition, PetAtlasState } from './petCatalog.js';

export type PetAtlasFrame = {
  x: number;
  y: number;
  width: number;
  height: number;
};

let activePetAtlasRuntimeStop: (() => void) | null = null;
let activePetAtlasSetState: ((requestedState: string) => void) | null = null;

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

/** Change the active atlas animation without replacing the decoded asset. */
export function setPetAtlasState(requestedState: string): void {
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
    let state = resolvePetAtlasState(atlas, atlas.defaultState);
    let frameCount = Math.max(1, state.descriptor.frames);
    let frame = 0;
    let lastFrameAt = 0;
    let animationFrame = 0;
    let stopped = false;

    const draw = (timestamp: number): void => {
      if (stopped) return;
      const rect = petAtlasFrameRect(atlas, state.name, frame);
      const displayWidth = Math.max(1, Math.round(canvas.clientWidth || rect.width));
      const displayHeight = Math.max(1, Math.round(canvas.clientHeight || rect.height));
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(displayWidth * dpr);
      canvas.height = Math.round(displayHeight * dpr);
      context.clearRect(0, 0, canvas.width, canvas.height);
      context.imageSmoothingEnabled = false;
      context.drawImage(image, rect.x, rect.y, rect.width, rect.height, 0, 0, canvas.width, canvas.height);
      if (!reducedMotion) {
        const frameDuration = 1000 / Math.max(1, state.descriptor.fps);
        if (timestamp - lastFrameAt >= frameDuration) {
          if (frame < frameCount - 1) {
            frame += 1;
            lastFrameAt = timestamp;
          } else if (state.descriptor.loop) {
            frame = 0;
            lastFrameAt = timestamp;
          } else {
            animationFrame = 0;
            return;
          }
        }
        animationFrame = window.requestAnimationFrame(draw);
      }
    };

    const describeState = (): void => {
      caption.textContent = `2D atlas loaded ${state.name} animation; ${frameCount} frames at ${state.descriptor.fps} fps.`;
    };

    activePetAtlasSetState = (requestedState: string) => {
      if (stopped) return;
      state = resolvePetAtlasState(atlas, requestedState);
      frameCount = Math.max(1, state.descriptor.frames);
      frame = 0;
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
