import { PROVIDER_GLYPHS } from '../providerGlyphs.js';
import { ProviderLogoView } from './ProviderLogoView.js';

/**
 * Provider identity chips with real brand logos.
 * `data-provider` hook preserved for evidence harness.
 */
export function ProviderGlyphs() {
  return (
    <div className="provider-glyphs" aria-label="Provider glyphs">
      {PROVIDER_GLYPHS.map((g) => (
        <span key={g.id} className="glyph-chip" data-provider={g.id}>
          <ProviderLogoView id={g.id} size={16} accent={g.accent} />
          {g.label}
        </span>
      ))}
    </div>
  );
}