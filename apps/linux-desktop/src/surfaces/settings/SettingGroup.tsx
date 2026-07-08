import type { ReactNode } from 'react';

export function SettingsSectionHeader({ title }: { title: string }) {
  return (
    <div className="settings-section-header" role="presentation">
      <span className="settings-section-header-label">{title}</span>
      <span className="settings-section-header-rule" aria-hidden="true" />
    </div>
  );
}

export function SettingGroup({
  title,
  children,
  id,
  sectionHeader = false,
  hideTitle = false
}: {
  title: string;
  children: ReactNode;
  id?: string;
  sectionHeader?: boolean;
  hideTitle?: boolean;
}) {
  const headingId = `setting-group-${title.replace(/\s+/g, '-')}`;
  return (
    <section className="setting-group" id={id} aria-labelledby={headingId} data-settings-tab={id}>
      {sectionHeader ? <SettingsSectionHeader title={title} /> : null}
      {hideTitle && sectionHeader ? (
        <h3 className="setting-group-title visually-hidden" id={headingId}>
          {title}
        </h3>
      ) : (
        <h3 className="setting-group-title" id={headingId}>
          {title}
        </h3>
      )}
      <div className="setting-group-body">{children}</div>
    </section>
  );
}