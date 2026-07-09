import type { CommunityLeaderboardCard } from './types.js';
import { tierLabel } from './consentStore.js';

type Props = { cards: CommunityLeaderboardCard[] };

export function CommunityLeaderboardCards({ cards }: Props) {
  return (
    <section className="community-panel glass-card" aria-labelledby="community-leaderboards-title">
      <h3 id="community-leaderboards-title">Leaderboard cards</h3>
      <div className="community-leaderboard-grid">
        {cards.map((card) => (
          <article key={card.tier} className="community-leaderboard-card glass-surface">
            <header>
              <strong>
                {tierLabel(card.tier)} — {card.geoLabel}
              </strong>
            </header>
            {card.belowThreshold ? (
              <p className="community-muted">
                Needs {card.kThreshold} more burners in {card.geoLabel}. No individual rows below k=
                {card.kThreshold}.
              </p>
            ) : (
              <ul className="community-leaderboard-list">
                {card.entries.map((entry) => (
                  <li key={entry.anonId}>
                    #{entry.rank} {entry.handle ?? entry.anonId} · {entry.totalTokens.toLocaleString()} tok · $
                    {entry.costUSD.toFixed(2)} · {entry.movement}
                  </li>
                ))}
              </ul>
            )}
          </article>
        ))}
      </div>
    </section>
  );
}