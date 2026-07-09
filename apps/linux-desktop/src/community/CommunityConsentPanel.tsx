import {
  cycleTriState,
  type CommunityConsentState,
  type ConsentTriState,
  type GeographyTier,
} from './consentStore.js';

type Props = {
  consent: CommunityConsentState;
  onChange: (next: CommunityConsentState) => void;
  onRevoke: () => void;
  statusMessage?: string;
};

function TriToggle({
  label,
  value,
  onCycle,
}: {
  label: string;
  value: ConsentTriState;
  onCycle: () => void;
}) {
  return (
    <button type="button" className="glass-interactive community-consent-chip" onClick={onCycle}>
      <span className="community-consent-chip__label">{label}</span>
      <span className="community-consent-chip__value">{value}</span>
    </button>
  );
}

export function CommunityConsentPanel({ consent, onChange, onRevoke, statusMessage }: Props) {
  const patch = (partial: Partial<CommunityConsentState>) =>
    onChange({ ...consent, ...partial, updatedAt: new Date().toISOString() });

  const patchTier = (tier: GeographyTier) => {
    const tiers = { ...consent.l2Tiers };
    if (tier === 'world') tiers.world = cycleTriState(tiers.world);
    if (tier === 'country') tiers.country = cycleTriState(tiers.country);
    if (tier === 'region') tiers.region = cycleTriState(tiers.region);
    if (tier === 'city') tiers.city = cycleTriState(tiers.city);
    patch({ l2Tiers: tiers });
  };

  return (
    <section className="community-panel glass-card" aria-labelledby="community-consent-title">
      <h3 id="community-consent-title">Consent center</h3>
      <p className="community-muted">{statusMessage}</p>
      <div className="community-consent-grid">
        <TriToggle label="L1 analytics" value={consent.l1Analytics} onCycle={() => patch({ l1Analytics: cycleTriState(consent.l1Analytics) })} />
        <TriToggle label="L2 rankings" value={consent.l2Rankings} onCycle={() => patch({ l2Rankings: cycleTriState(consent.l2Rankings) })} />
        <TriToggle label="L3 looking glass" value={consent.l3LookingGlass} onCycle={() => patch({ l3LookingGlass: cycleTriState(consent.l3LookingGlass) })} />
        <TriToggle label="Location" value={consent.locationConsent} onCycle={() => patch({ locationConsent: cycleTriState(consent.locationConsent) })} />
        <TriToggle label="City tier" value={consent.l2Tiers.city} onCycle={() => patchTier('city')} />
        <TriToggle label="Region tier" value={consent.l2Tiers.region} onCycle={() => patchTier('region')} />
        <TriToggle label="Country tier" value={consent.l2Tiers.country} onCycle={() => patchTier('country')} />
        <TriToggle label="World tier" value={consent.l2Tiers.world} onCycle={() => patchTier('world')} />
      </div>
      {consent.l2Tiers.city === 'granted' && consent.locationConsent === 'granted' ? (
        <label className="community-city-manual">
          <span className="community-muted">Your city (manual — Linux has no OS location)</span>
          <input
            type="text"
            className="glass-interactive community-city-input"
            value={consent.manualCityInput ?? ''}
            placeholder="e.g. San Francisco"
            onChange={(e) => patch({ manualCityInput: e.target.value })}
          />
        </label>
      ) : null}
      <button type="button" className="glass-interactive community-revoke" onClick={onRevoke}>
        Pause / revoke participation
      </button>
    </section>
  );
}