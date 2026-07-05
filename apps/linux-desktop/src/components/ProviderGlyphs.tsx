import { PROVIDER_GLYPHS } from '../providerGlyphs.js';

/**
 * Provider identity chips (`.glyph-chip[data-provider="<id>"]`).
 * Accent colors come from the shared provider glyph module, not per-surface taste.
 */
export function ProviderGlyphs() {
  return (
    <div className="provider-glyphs" aria-label="Provider glyphs">
      {PROVIDER_GLYPHS.map((g) => (
        <span key={g.id} className="glyph-chip" data-provider={g.id}>
          <span className="glyph-dot" style={{ background: g.accent }} aria-hidden="true" />
          {g.label}
        </span>
      ))}
    </div>
  );
}
