import type { ReactNode } from 'react';

export function SettingRow({
  label,
  description,
  control,
  readOnlyNote,
  iconGlyph
}: {
  label: string;
  description: string;
  control: ReactNode;
  readOnlyNote?: string;
  /** Text glyph in a tinted tile — mirrors macOS Settings toggle / drill row icons. */
  iconGlyph?: string;
}) {
  return (
    <div className="setting-row">
      {iconGlyph ? (
        <span className="setting-row-icon" aria-hidden="true">
          {iconGlyph}
        </span>
      ) : null}
      <div className="setting-row-copy">
        <span className="setting-row-label">{label}</span>
        <p className="muted setting-row-desc">{description}</p>
        {readOnlyNote ? <p className="muted setting-row-managed">{readOnlyNote}</p> : null}
      </div>
      <div className="setting-row-control">{control}</div>
    </div>
  );
}