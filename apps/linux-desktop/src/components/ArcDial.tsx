import type { CSSProperties } from 'react';
import { findProviderGlyph } from '../providerGlyphs.js';
import type { SubscriptionBucketView } from '../surfaces/quota/quotaModel.js';

type ArcDialProps = {
  outer: SubscriptionBucketView | null;
  inner: SubscriptionBucketView | null;
  providerId: string;
  size?: number;
  dominantLabel?: string;
};

function ringPath(cx: number, cy: number, r: number): string {
  return `M ${cx} ${cy - r} A ${r} ${r} 0 1 1 ${cx - 0.01} ${cy - r}`;
}

function arcLength(r: number, fraction: number): number {
  return 2 * Math.PI * r * Math.max(0, Math.min(1, fraction));
}

function paceAngle(fraction: number | null | undefined): number | null {
  if (fraction == null) return null;
  return -90 + 360 * Math.max(0, Math.min(1, fraction));
}

export function ArcDial({ outer, inner, providerId, size = 112, dominantLabel }: ArcDialProps) {
  const glyph = findProviderGlyph(providerId);
  const accent = glyph.accent.startsWith('#') ? 'var(--color-brass-core)' : glyph.accent;
  const cx = size / 2;
  const cy = size / 2;
  const outerR = size * 0.42;
  const innerR = size * 0.3;
  const outerFrac = outer ? outer.remainingPct / 100 : null;
  const innerFrac = inner ? inner.remainingPct / 100 : null;
  const centerPct = outer?.remainingPct ?? inner?.remainingPct ?? 0;
  const subLabel = dominantLabel ?? outer?.label ?? inner?.label ?? 'Remaining';

  const outerLen = outerFrac != null ? arcLength(outerR, outerFrac) : 0;
  const innerLen = innerFrac != null ? arcLength(innerR, innerFrac) : 0;
  const outerCirc = 2 * Math.PI * outerR;
  const innerCirc = 2 * Math.PI * innerR;

  const outerPace = paceAngle(outer?.pace?.tickFraction);
  const innerPace = paceAngle(inner?.pace?.tickFraction);

  return (
    <div className="arc-dial" style={{ '--arc-accent': accent, '--arc-size': `${size}px` } as CSSProperties}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} role="img" aria-label={`${centerPct}% remaining`}>
        <circle cx={cx} cy={cy} r={outerR} className="arc-dial-track" fill="none" />
        {outerFrac != null ? (
          <path
            d={ringPath(cx, cy, outerR)}
            className="arc-dial-ring arc-dial-ring--outer"
            fill="none"
            pathLength={outerCirc}
            strokeDasharray={`${outerLen} ${outerCirc}`}
          />
        ) : (
          <circle cx={cx} cy={cy} r={outerR} className="arc-dial-ring arc-dial-ring--dashed" fill="none" />
        )}
        <circle cx={cx} cy={cy} r={innerR} className="arc-dial-track arc-dial-track--inner" fill="none" />
        {innerFrac != null ? (
          <path
            d={ringPath(cx, cy, innerR)}
            className="arc-dial-ring arc-dial-ring--inner"
            fill="none"
            pathLength={innerCirc}
            strokeDasharray={`${innerLen} ${innerCirc}`}
          />
        ) : null}
        {outerPace != null ? (
          <g transform={`rotate(${outerPace} ${cx} ${cy})`}>
            <circle cx={cx} cy={cy - outerR} r={3} className="arc-dial-pace" />
          </g>
        ) : null}
        {innerPace != null ? (
          <g transform={`rotate(${innerPace} ${cx} ${cy})`}>
            <circle cx={cx} cy={cy - innerR} r={2.5} className="arc-dial-pace arc-dial-pace--inner" />
          </g>
        ) : null}
      </svg>
      <div className="arc-dial-center">
        <span className="arc-dial-pct mono">{centerPct}%</span>
        <span className="arc-dial-sub muted">{subLabel}</span>
      </div>
    </div>
  );
}