import { useMemo } from 'react';
import { HomeLivingLayout } from '../../dashboard/HomeLivingLayout.js';
import { createHomeSlot, createRowAppetite } from '../../dashboard/homeSpaceBudget.js';
import { HomeSection } from './HomeSection.js';
import {
  ATLAS_ROW_UNIT,
  formatPercent,
  type AtlasAttentionRow,
  type AtlasKindRank,
  type AtlasSplit as AtlasSplitModel
} from './overviewHomeModel.js';

const SLOT = {
  split: 'atlas.split',
  attention: 'atlas.attention',
  kinds: 'atlas.kinds'
} as const;

export function AtlasSplit({
  split,
  attention,
  rest,
  kinds
}: {
  split: AtlasSplitModel;
  attention: AtlasAttentionRow[];
  rest: AtlasAttentionRow[];
  kinds: AtlasKindRank[];
}) {
  const slots = useMemo(
    () => [
      createHomeSlot({
        id: SLOT.split,
        rank: 0,
        floor: 108,
        ideal: 124,
        spans: true
      }),
      createHomeSlot({
        id: SLOT.attention,
        rank: 1,
        floor: 45 + ATLAS_ROW_UNIT * 2,
        ideal: 45 + ATLAS_ROW_UNIT * 6,
        stretch: 1,
        rows: createRowAppetite({
          available: attention.length,
          baseline: Math.min(2, attention.length),
          unit: ATLAS_ROW_UNIT,
          ceiling: 12
        })
      }),
      createHomeSlot({
        id: SLOT.kinds,
        rank: 2,
        floor: 45 + ATLAS_ROW_UNIT * 2,
        ideal: 45 + ATLAS_ROW_UNIT * 6,
        stretch: 1,
        rows: createRowAppetite({
          available: kinds.length > 0 ? kinds.length : rest.length,
          baseline: Math.min(2, kinds.length > 0 ? kinds.length : rest.length),
          unit: ATLAS_ROW_UNIT,
          ceiling: 12
        })
      })
    ],
    [attention.length, kinds.length, rest.length]
  );

  return (
    <HomeLivingLayout slots={slots} gutter={16} padding={8}>
      {(id, placement) => {
        switch (id) {
          case SLOT.split:
            return <SplitHeader split={split} />;
          case SLOT.attention:
            return (
              <Ladder
                eyebrow="Needs you"
                accent="var(--color-seal-crimson)"
                rows={attention.slice(0, placement.rowCount)}
                empty="Clear"
              />
            );
          case SLOT.kinds:
            return kinds.length > 0 ? (
              <KindLadder rows={kinds.slice(0, placement.rowCount)} />
            ) : (
              <Ladder
                eyebrow="Everything else"
                accent="var(--color-tier-server-readable)"
                rows={rest.slice(0, placement.rowCount)}
                empty="Nothing later"
              />
            );
          default:
            return null;
        }
      }}
    </HomeLivingLayout>
  );
}

function SplitHeader({ split }: { split: AtlasSplitModel }) {
  return (
    <HomeSection
      eyebrow="Split"
      accent="var(--color-brass-bright)"
      emphasis="featured"
      accessory={<span className="atlas-gap">{split.gapLabel}</span>}
    >
      <div className="atlas-split">
        <figure className="atlas-split__cell">
          <figcaption>Needs you</figcaption>
          <p className="atlas-split__value tabular-nums living-tick">{split.needsYou}</p>
          <p className="muted">{split.needsYouCaption}</p>
        </figure>
        <figure className="atlas-split__cell">
          <figcaption>Everything else</figcaption>
          <p className="atlas-split__value tabular-nums living-tick">{split.everythingElse}</p>
          <p className="muted">{split.elseCaption}</p>
        </figure>
        <figure className="atlas-split__cell">
          <figcaption>Attention share</figcaption>
          <p className="atlas-split__value tabular-nums living-tick">{formatPercent(split.unreadShare)}</p>
          <p className="muted">
            {split.needsYou} of {split.total}
          </p>
        </figure>
      </div>
    </HomeSection>
  );
}

function Ladder({
  eyebrow,
  accent,
  rows,
  empty
}: {
  eyebrow: string;
  accent: string;
  rows: AtlasAttentionRow[];
  empty: string;
}) {
  return (
    <HomeSection eyebrow={eyebrow} accent={accent}>
      {rows.length === 0 ? (
        <p className="home-section__empty">{empty}</p>
      ) : (
        <ol className="atlas-ladder">
          {rows.map((row) => (
            <li key={row.id} className="atlas-ladder__row">
              <span className={`atlas-ladder__priority atlas-ladder__priority--${row.priority}`}>
                {row.priority}
              </span>
              <span className="atlas-ladder__title">{row.title}</span>
              <span className="atlas-ladder__comparison muted">{row.comparison}</span>
            </li>
          ))}
        </ol>
      )}
    </HomeSection>
  );
}

function KindLadder({ rows }: { rows: AtlasKindRank[] }) {
  return (
    <HomeSection eyebrow="By kind" accent="var(--color-tier-server-readable)">
      {rows.length === 0 ? (
        <p className="home-section__empty">Nothing detected</p>
      ) : (
        <ol className="atlas-ladder">
          {rows.map((row) => (
            <li key={row.kind} className="atlas-ladder__row">
              <span className="atlas-ladder__swatch" style={{ background: row.accent }} aria-hidden />
              <span className="atlas-ladder__title">{row.label}</span>
              <span className="atlas-ladder__comparison muted">
                {row.count > 0 ? `${row.count} · ` : ''}
                {formatPercent(row.share)} of the field
              </span>
            </li>
          ))}
        </ol>
      )}
    </HomeSection>
  );
}
