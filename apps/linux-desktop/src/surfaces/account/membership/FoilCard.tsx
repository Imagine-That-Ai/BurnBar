import type { ReactNode } from 'react';

export function FoilCard({
  eyebrow,
  title,
  detail,
  active = false,
  children
}: {
  eyebrow: string;
  title: string;
  detail: string;
  active?: boolean;
  children?: ReactNode;
}) {
  return (
    <div className={`membership-foil-card ${active ? 'membership-foil-card--active' : ''}`}>
      <div className="membership-crest" aria-hidden="true">
        <span />
      </div>
      <div className="membership-foil-copy">
        <p className="membership-eyebrow">{eyebrow}</p>
        <h3>{title}</h3>
        <p className="muted">{detail}</p>
      </div>
      {children ? <div className="membership-foil-actions">{children}</div> : null}
    </div>
  );
}
