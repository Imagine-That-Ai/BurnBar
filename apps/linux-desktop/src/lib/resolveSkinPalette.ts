import { housePalette } from '@openburnbar/gl-engine/engine/palette';
import type { KernelPalette } from '@openburnbar/gl-engine/engine/types';
import type { ShellSkin } from '../state/shellStore.js';

/**
 * Linux shell skin → kernel accent ramp (macOS oracle: editorial ember vs aurora teal).
 * Dark house bg/ink/intensity are preserved; only the four-stop accent journey changes.
 */
export function resolveSkinPalette(skin: ShellSkin): KernelPalette {
  const base = housePalette('dark');
  if (skin === 'aurora') {
    return {
      ...base,
      accents: [
        [60, 214, 192], // tier-end-to-end #3cd6c0
        [110, 231, 255], // aurora gradient end #6ee7ff
        [48, 190, 210], // deeper reef
        [72, 220, 238], // mid cyan
      ],
    };
  }
  return {
    ...base,
    accents: [
      [250, 107, 6], // brass-core #fa6b06
      [253, 196, 44], // brass-bright #fdc42c
      [238, 24, 3], // brass-deep #ee1803
      [255, 128, 32], // ember mid
    ],
  };
}