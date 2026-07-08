/**
 * Type-only stub for the glyph subsystem.
 *
 * The full glyph/swarm field (rasterization + SDF, DOM-coupled) lives in
 * imaginethat-llc and is NOT vendored — the console backdrop is a pure ambient
 * field with no logo-formation coupling. The engine references `GlyphField` only
 * as an optional type (`setGlyphField?` is never called by the console host), so
 * this verbatim copy of the interface keeps the vendored files compiling without
 * pulling in the rasterizer.
 */
export interface GlyphField {
  /** RGBA8 texel buffer, length = size*size*4. R=signed dist, G=coverage. */
  data: Uint8Array;
  /** Square grid edge (texels). */
  size: number;
  /** Tight silhouette bbox within the grid, normalized 0..1 (y-down). */
  content: { x: number; y: number; w: number; h: number };
  /** Identity for dedupe/caching. */
  key: string;
}
