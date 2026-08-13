type FireStop = readonly [position: number, rgba: readonly [number, number, number, number]];

const FIRST_FIRE_STOP: FireStop = [0, [10, 5, 4, 0]];
const LAST_FIRE_STOP: FireStop = [1, [184, 18, 38, 255]];
const FIRE_STOPS: readonly FireStop[] = [
  FIRST_FIRE_STOP,
  [0.1, [254, 243, 199, 185]],
  [0.26, [251, 191, 36, 245]],
  [0.44, [251, 139, 30, 255]],
  [0.6, [250, 107, 6, 255]],
  [0.76, [248, 58, 42, 255]],
  [0.9, [225, 29, 46, 255]],
  LAST_FIRE_STOP
];

const LIQUID_METAL = {
  angle: 1.2217,
  contour: 0.4,
  distortion: 0.07,
  repetition: 2,
  scale: 0.62,
  shiftBlue: 0.3,
  shiftRed: 0.3,
  softness: 0.1
} as const;

let disposeActiveVisuals = (): void => {};

const clamp = (value: number, low = 0, high = 1): number => Math.min(high, Math.max(low, value));
const fract = (value: number): number => value - Math.floor(value);

function smoothstep(edge0: number, edge1: number, value: number): number {
  if (edge0 === edge1) {
    return value < edge0 ? 0 : 1;
  }
  const amount = clamp((value - edge0) / (edge1 - edge0));
  return amount * amount * (3 - 2 * amount);
}

function noiseHash(x: number, y: number): number {
  return fract(Math.sin(x * 127.1 + y * 311.7) * 43_758.5453);
}

function valueNoise(x: number, y: number): number {
  const integerX = Math.floor(x);
  const integerY = Math.floor(y);
  const fractionX = x - integerX;
  const fractionY = y - integerY;
  const smoothX = fractionX * fractionX * (3 - 2 * fractionX);
  const smoothY = fractionY * fractionY * (3 - 2 * fractionY);
  const topLeft = noiseHash(integerX, integerY);
  const topRight = noiseHash(integerX + 1, integerY);
  const bottomLeft = noiseHash(integerX, integerY + 1);
  const bottomRight = noiseHash(integerX + 1, integerY + 1);
  return (
    (topLeft +
      (topRight - topLeft) * smoothX +
      (bottomLeft - topLeft) * smoothY +
      (topLeft - topRight - bottomLeft + bottomRight) * smoothX * smoothY) *
      2 -
    1
  );
}

function liquidMetalProfile(phase: number, blur: number): number {
  let chrome = 0.04;
  chrome += 0.92 * smoothstep(0, 0.1 + blur, phase);
  chrome -= 0.8 * smoothstep(0.12, 0.18 + blur, phase);
  chrome += 0.66 * smoothstep(0.22, 0.55 + blur, phase);
  chrome -= 0.72 * smoothstep(0.64 - 0.3 * blur, 0.98, phase);
  return clamp(chrome, 0.02, 1);
}

function buildFirePalette(levels: number): Uint8ClampedArray {
  const palette = new Uint8ClampedArray(levels * 4);
  for (let level = 0; level < levels; level += 1) {
    const amount = level / (levels - 1);
    let lower = FIRST_FIRE_STOP;
    let upper = LAST_FIRE_STOP;
    for (let index = 0; index < FIRE_STOPS.length - 1; index += 1) {
      const candidate = FIRE_STOPS[index];
      const next = FIRE_STOPS[index + 1];
      if (candidate && next && amount >= candidate[0] && amount <= next[0]) {
        lower = candidate;
        upper = next;
        break;
      }
    }
    const span = upper[0] - lower[0] || 1;
    const interpolation = (amount - lower[0]) / span;
    for (let channel = 0; channel < 4; channel += 1) {
      const lowerValue = lower[1][channel] ?? 0;
      const upperValue = upper[1][channel] ?? 0;
      palette[level * 4 + channel] = lowerValue + (upperValue - lowerValue) * interpolation;
    }
  }
  return palette;
}

function prepareCanvas(canvas: HTMLCanvasElement, fallbackWidth: number, fallbackHeight: number): [number, number] {
  const bounds = canvas.getBoundingClientRect();
  const cssWidth = Math.max(1, Math.round(bounds.width || fallbackWidth));
  const cssHeight = Math.max(1, Math.round(bounds.height || fallbackHeight));
  const ratio = Math.max(1, Math.min(3, window.devicePixelRatio || 1));
  canvas.width = Math.round(cssWidth * ratio);
  canvas.height = Math.round(cssHeight * ratio);
  return [canvas.width, canvas.height];
}

function animateFire(canvas: HTMLCanvasElement, schedule: (callback: () => void) => void): void {
  const [width, height] = prepareCanvas(canvas, 204, 26);
  const context = canvas.getContext('2d', { alpha: true });
  if (!context) {
    return;
  }
  const levels = 48;
  const palette = buildFirePalette(levels);
  const heat = new Uint8Array(width * height);
  const image = context.createImageData(width, height);

  const seed = (): void => {
    for (let x = 0; x < width; x += 1) {
      const ramp = 0.28 + 0.72 * (x / (width - 1));
      heat[(height - 1) * width + x] = Math.min(levels - 1, Math.round((levels - 1) * ramp));
    }
  };
  const spread = (): void => {
    for (let y = 1; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const source = y * width + x;
        const decay = Math.floor(Math.random() * 3);
        const targetX = x - decay + 1;
        const target = source - width - decay + 1;
        if (targetX < 0 || targetX >= width || target < 0) {
          continue;
        }
        heat[target] = Math.max(0, (heat[source] ?? 0) - (decay & 1));
      }
    }
  };
  const paint = (): void => {
    for (let pixel = 0; pixel < width * height; pixel += 1) {
      const paletteOffset = (heat[pixel] ?? 0) * 4;
      const imageOffset = pixel * 4;
      image.data[imageOffset] = palette[paletteOffset] ?? 0;
      image.data[imageOffset + 1] = palette[paletteOffset + 1] ?? 0;
      image.data[imageOffset + 2] = palette[paletteOffset + 2] ?? 0;
      image.data[imageOffset + 3] = palette[paletteOffset + 3] ?? 0;
    }
    for (let spark = 0; spark < 22; spark += 1) {
      const pixel = Math.floor(Math.random() * width * height);
      if ((heat[pixel] ?? 0) < levels * 0.5) {
        continue;
      }
      const offset = pixel * 4;
      image.data[offset] = 255;
      image.data[offset + 1] = 122;
      image.data[offset + 2] = 136;
      image.data[offset + 3] = 255;
    }
    context.putImageData(image, 0, 0);
  };

  seed();
  for (let frame = 0; frame < 60; frame += 1) {
    spread();
  }
  const animate = (): void => {
    seed();
    spread();
    paint();
    schedule(animate);
  };
  animate();
}

function blurLogoMask(alpha: Float32Array, size: number): Float32Array {
  const blurred = Float32Array.from(alpha);
  const temporary = new Float32Array(size * size);
  for (let pass = 0; pass < 4; pass += 1) {
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        let sum = 0;
        let samples = 0;
        for (let offset = -2; offset <= 2; offset += 1) {
          const sampleX = x + offset;
          if (sampleX >= 0 && sampleX < size) {
            sum += blurred[y * size + sampleX] ?? 0;
            samples += 1;
          }
        }
        temporary[y * size + x] = sum / samples;
      }
    }
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        let sum = 0;
        let samples = 0;
        for (let offset = -2; offset <= 2; offset += 1) {
          const sampleY = y + offset;
          if (sampleY >= 0 && sampleY < size) {
            sum += temporary[sampleY * size + x] ?? 0;
            samples += 1;
          }
        }
        blurred[y * size + x] = sum / samples;
      }
    }
  }
  return blurred;
}

function animateLiquidMetalKnob(canvas: HTMLCanvasElement, schedule: (callback: () => void) => void): void {
  const [size] = prepareCanvas(canvas, 50, 50);
  const context = canvas.getContext('2d');
  if (!context) {
    return;
  }
  const logo = new Image();
  logo.onload = (): void => {
    if (!canvas.isConnected) {
      return;
    }
    try {
      const maskCanvas = document.createElement('canvas');
      maskCanvas.width = size;
      maskCanvas.height = size;
      const maskContext = maskCanvas.getContext('2d');
      if (!maskContext) {
        return;
      }
      const padding = size * 0.11;
      maskContext.drawImage(logo, padding, padding, size - padding * 2, size - padding * 2);
      const source = maskContext.getImageData(0, 0, size, size).data;
      const alpha = new Float32Array(size * size);
      for (let pixel = 0; pixel < size * size; pixel += 1) {
        alpha[pixel] = (source[pixel * 4 + 3] ?? 0) / 255;
      }
      const blurred = blurLogoMask(alpha, size);
      const edge = new Float32Array(size * size);
      for (let pixel = 0; pixel < size * size; pixel += 1) {
        edge[pixel] = clamp(1 - (blurred[pixel] ?? 0));
      }
      const image = context.createImageData(size, size);
      const directionX = Math.cos(LIQUID_METAL.angle);
      const directionY = Math.sin(LIQUID_METAL.angle);
      const contour = smoothstep(0.1, 1, LIQUID_METAL.contour);
      const blur = 0.02 + 0.45 * LIQUID_METAL.softness;
      const scale = 0.55 * LIQUID_METAL.scale;

      const paint = (time: number): void => {
        for (let y = 0; y < size; y += 1) {
          for (let x = 0; x < size; x += 1) {
            const pixel = y * size + x;
            const output = pixel * 4;
            const coverage = alpha[pixel] ?? 0;
            if (coverage <= 0.004) {
              image.data[output + 3] = 0;
              continue;
            }
            const fieldX = (x / size - 0.5) / scale;
            const fieldY = (y / size - 0.5) / scale;
            const edgeAmount = edge[pixel] ?? 0;
            const noise = valueNoise(fieldX * 1.3, fieldY * 1.3 + time * 0.2);
            const distortedEdge = clamp(edgeAmount + (1 - edgeAmount) * LIQUID_METAL.distortion * (0.5 + 0.5 * noise));
            let phase = directionX * fieldX + directionY * fieldY;
            phase *= 1 - distortedEdge * contour;
            phase -= 1.7 * distortedEdge * contour;
            phase *= 0.9 * LIQUID_METAL.repetition;
            phase -= 0.1 * time;
            const dispersion = 0.25 + 0.75 * distortedEdge;
            const red = liquidMetalProfile(fract(phase + LIQUID_METAL.shiftRed * 0.05 * dispersion), blur);
            const green = liquidMetalProfile(fract(phase), blur);
            const blue = liquidMetalProfile(fract(phase - LIQUID_METAL.shiftBlue * 0.05 * dispersion), blur);
            const under = liquidMetalProfile(fract(phase * 0.47 - 0.06 * time + 0.31), blur + 0.18);
            const multiplier = 0.88 + 0.24 * under;
            image.data[output] = 255 * clamp(red * multiplier);
            image.data[output + 1] = 255 * clamp(green * multiplier);
            image.data[output + 2] = 255 * clamp(blue * multiplier);
            image.data[output + 3] = 255 * coverage;
          }
        }
        context.putImageData(image, 0, 0);
        canvas.dataset.rendered = 'true';
        const fallback = canvas.parentElement?.querySelector<HTMLImageElement>('.mode-knob-fallback');
        if (fallback) {
          fallback.hidden = true;
        }
      };

      const startedAt = performance.now();
      const animate = (): void => {
        paint((performance.now() - startedAt) / 1_000);
        schedule(animate);
      };
      animate();
    } catch {
      // Preserve the image fallback if canvas pixel access is unavailable.
    }
  };
  logo.src = 'icons/app-logo.svg';
}

export function initializeModeVisuals(root: HTMLElement): void {
  disposeActiveVisuals();
  disposeActiveVisuals = (): void => {};
  if (typeof CanvasRenderingContext2D === 'undefined') {
    return;
  }
  const popover = root.querySelector<HTMLElement>('#mode-popover');
  if (!popover || popover.hidden) {
    return;
  }
  const fire = root.querySelector<HTMLCanvasElement>('.mode-fire');
  const knob = root.querySelector<HTMLCanvasElement>('.mode-knob');
  const timers = new Map<() => void, number>();
  const pending = new Set<() => void>();
  let disposed = false;
  const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
  const canAnimate = (): boolean =>
    !disposed && popover.isConnected && !popover.hidden && document.visibilityState === 'visible';
  const arm = (callback: () => void): void => {
    if (!canAnimate() || timers.has(callback)) {
      return;
    }
    const timer = window.setTimeout(() => {
      timers.delete(callback);
      pending.delete(callback);
      if (canAnimate()) {
        callback();
      }
    }, 55);
    timers.set(callback, timer);
  };
  const schedule = (callback: () => void): void => {
    if (disposed || reduceMotion) {
      return;
    }
    pending.add(callback);
    arm(callback);
  };
  const dispose = (): void => {
    disposed = true;
    for (const timer of timers.values()) {
      window.clearTimeout(timer);
    }
    timers.clear();
    pending.clear();
    document.removeEventListener('visibilitychange', handleVisibility);
  };
  const handleVisibility = (): void => {
    if (document.visibilityState !== 'visible') {
      for (const timer of timers.values()) {
        window.clearTimeout(timer);
      }
      timers.clear();
      return;
    }
    for (const callback of pending) {
      arm(callback);
    }
  };
  document.addEventListener('visibilitychange', handleVisibility);
  disposeActiveVisuals = dispose;
  if (fire) {
    try {
      animateFire(fire, schedule);
    } catch {
      // The CSS gradient remains visible if Safari cannot allocate the fire canvas.
    }
  }
  if (knob) {
    try {
      animateLiquidMetalKnob(knob, schedule);
    } catch {
      // The logo image remains visible if Safari cannot initialize the liquid-metal canvas.
    }
  }
}
