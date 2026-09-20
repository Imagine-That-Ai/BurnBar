/**
 * Pure pack/unpack of a float into an RGBA8 texel (and back), for a hypothetical
 * future packed-float sim on no-float hardware.
 *
 * NOT wired into any launch kernel and NOT a public `SimFormat` (D7): on
 * no-float hardware the host resolves a `requiresFloatTex` kernel to its 2D
 * `fallbackId` (visually richer than a degraded RGBA8 PDE). Specified + tested
 * so a future no-float-but-want-sim path is a small, verified addition.
 *
 * Round-trips within ~1e-5 over [0,1) on a sampled grid.
 */

/** Pack a float in [0,1) into 4 bytes (one per RGBA channel, 0–255). */
export function packFloatToRGBA8(v: number): [number, number, number, number] {
  const clamped = Math.min(Math.max(v, 0), 0.9999999);
  const r = Math.floor(clamped * 256);
  const g = Math.floor(clamped * 65536) - r * 256;
  const b = Math.floor(clamped * 16777216) - r * 65536 - g * 256;
  const a = Math.floor(clamped * 4294967296) - r * 16777216 - g * 65536 - b * 256;
  return [r & 255, g & 255, b & 255, a & 255];
}

/** Unpack 4 bytes (0–255 each) back into a float in [0,1). */
export function unpackRGBA8ToFloat(
  r: number,
  g: number,
  b: number,
  a: number
): number {
  return (
    ((r & 255) / 256 +
      (g & 255) / 65536 +
      (b & 255) / 16777216 +
      (a & 255) / 4294967296)
  );
}
