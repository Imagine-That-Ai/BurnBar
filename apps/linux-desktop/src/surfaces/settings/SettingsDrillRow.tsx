import type { ReactNode } from 'react';

export function SettingsIconTile({
  glyph,
  tint,
  size = 'md'
}: {
  glyph: string;
  tint: string;
  size?: 'sm' | 'md';
}) {
  return (
    <span
      className={`settings-icon-tile settings-icon-tile--${size}`}
      style={{ ['--settings-icon-tint' as string]: tint }}
      aria-hidden="true"
    >
      {glyph}
    </span>
  );
}

export function SettingsDrillRow({
  iconGlyph,
  iconTint,
  title,
  subtitle,
  value,
  valueTone,
  badge,
  trailing,
  onActivate,
  active,
  as: Tag = 'button'
}: {
  iconGlyph: string;
  iconTint: string;
  title: string;
  subtitle?: string;
  value?: string;
  valueTone?: 'muted' | 'ok' | 'warn';
  badge?: string;
  trailing?: ReactNode;
  onActivate?: () => void;
  active?: boolean;
  as?: 'button' | 'div';
}) {
  const className = `settings-drill-row${active ? ' settings-drill-row--active' : ''}`;
  const body = (
    <>
      <SettingsIconTile glyph={iconGlyph} tint={iconTint} />
      <span className="settings-drill-row-copy">
        <span className="settings-drill-row-title">{title}</span>
        {subtitle ? <span className="settings-drill-row-subtitle">{subtitle}</span> : null}
      </span>
      <span className="settings-drill-row-trail">
        {badge ? <span className="settings-drill-row-badge">{badge}</span> : null}
        {value ? (
          <span className={`settings-drill-row-value settings-drill-row-value--${valueTone ?? 'muted'}`}>{value}</span>
        ) : null}
        {trailing ?? <span className="settings-drill-row-chevron" aria-hidden="true">›</span>}
      </span>
    </>
  );

  if (Tag === 'div') {
    return <div className={className}>{body}</div>;
  }

  return (
    <button type="button" className={className} onClick={onActivate} aria-current={active ? 'page' : undefined}>
      {body}
    </button>
  );
}