import { findProviderGlyph } from '../../providerGlyphs.js';
import type { ProviderCatalogEntry } from '../../tauriBridge.js';
import { AccountChips } from './AccountChips.js';
import { ProviderActivityBadge } from './ProviderActivityBadge.js';
import { QuotaBucketBar } from './QuotaBucketBar.js';
import { QuotaSourceBadge } from './QuotaSourceBadge.js';
import { ProviderLogoView } from '../../components/ProviderLogoView.js';
import { resolveProviderCardMeta } from './providerAccountVisual.js';

export function ProviderCard({
  provider,
  quotaRefreshing = false
}: {
  provider: ProviderCatalogEntry;
  quotaRefreshing?: boolean;
}) {
  const glyph = findProviderGlyph(provider.id);
  const meta = resolveProviderCardMeta(provider);

  return (
    <article className="provider-card" data-provider={provider.id}>
      <header className="provider-card-header">
        <div className="provider-card-title">
          <ProviderLogoView id={provider.id} size={28} accent={glyph.accent} className="provider-card-logo" />
          <h3 className="provider-card-label">{provider.label}</h3>
          {meta.quotaSource ? (
            <QuotaSourceBadge source={meta.quotaSource} confidence={meta.quotaConfidence} />
          ) : null}
          {quotaRefreshing ? <ProviderActivityBadge compact /> : null}
        </div>
        <AccountChips
          accountLabel={provider.accountLabel}
          buckets={provider.quotaBuckets}
          storage={meta.storage}
          status={meta.status}
        />
      </header>
      <ul className="provider-bucket-list">
        {provider.quotaBuckets.map((bucket) => (
          <li key={bucket.id}>
            <QuotaBucketBar bucket={bucket} accentColor={glyph.accent} />
          </li>
        ))}
      </ul>
    </article>
  );
}
