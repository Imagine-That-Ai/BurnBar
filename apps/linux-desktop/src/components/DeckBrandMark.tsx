import { useShellStore } from '../state/shellStore.js';

const OPENBURNBAR_LOGO = '/provider-logos/openburnbar.png';

type DeckBrandMarkProps = {
  /** When true, only the logo mark is shown (no adjacent wordmark). */
  logoOnly?: boolean;
};

/**
 * Top-left OpenBurnBar brand control — navigates to Overview.
 */
export function DeckBrandMark({ logoOnly = false }: DeckBrandMarkProps) {
  const setRoute = useShellStore((s) => s.setRoute);

  return (
    <button
      type="button"
      className={`deck-brand-btn${logoOnly ? ' deck-brand-btn--logo-only' : ''}`}
      onClick={() => setRoute('overview')}
      aria-label="OpenBurnBar — go to dashboard overview"
    >
      <span className="deck-brand-mark" aria-hidden="true">
        <img className="deck-brand-logo" src={OPENBURNBAR_LOGO} alt="" width={30} height={30} decoding="async" />
      </span>
      {!logoOnly ? (
        <span className="deck-wordmark">
          Open<span className="deck-wordmark-accent">BurnBar</span>
        </span>
      ) : null}
    </button>
  );
}