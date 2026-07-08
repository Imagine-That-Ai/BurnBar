import { PROVIDER_GLYPHS } from '../../providerGlyphs.js';
import type { MixEntry } from '../../tauriBridge.js';

function accentForEntry(entry: MixEntry): string {
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === entry.id);
  return glyph?.accent ?? 'var(--color-brass-core)';
}

export function MixBar({
  title,
  entries,
  ariaLabel
}: {
  title: string;
  entries: MixEntry[];
  ariaLabel: string;
}) {
  const total = entries.reduce((s, e) => s + e.pct, 0);
  const scale = total > 0 ? 100 / total : 0;

  return (
    <div className="insights-mix-glass">
      <figure className="insights-mix">
        <figcaption className="insights-mix-title">{title}</figcaption>
        <div
          className="insights-mix-bar"
          role="img"
          aria-label={ariaLabel}
        >
          {entries.map((e) => (
            <div
              key={e.id}
              className="insights-mix-segment"
              style={{
                width: `${(e.pct * scale).toFixed(2)}%`,
                background: accentForEntry(e)
              }}
              title={`${e.label} ${e.pct}%`}
            />
          ))}
        </div>
        <ul className="insights-mix-legend">
          {entries.map((e) => (
            <li key={e.id}>
              <span className="insights-mix-swatch" style={{ background: accentForEntry(e) }} aria-hidden="true" />
              <span className="insights-mix-label">{e.label}</span>
              <span className="insights-mix-pct">{e.pct}%</span>
            </li>
          ))}
        </ul>
        <table className="visually-hidden">
          <caption>{title}</caption>
          <thead>
            <tr>
              <th scope="col">Label</th>
              <th scope="col">Share</th>
            </tr>
          </thead>
          <tbody>
            {entries.map((e) => (
              <tr key={e.id}>
                <td>{e.label}</td>
                <td>{e.pct}%</td>
              </tr>
            ))}
          </tbody>
        </table>
      </figure>
    </div>
  );
}