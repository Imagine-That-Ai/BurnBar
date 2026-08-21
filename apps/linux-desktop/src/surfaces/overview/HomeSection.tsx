import type { ReactNode } from 'react';

export function HomeSection({
  eyebrow,
  accent = 'var(--color-brass-core)',
  emphasis = 'standard',
  accessory,
  children
}: {
  eyebrow: string;
  accent?: string;
  emphasis?: 'standard' | 'featured';
  accessory?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section
      className={`home-section home-section--${emphasis}`}
      style={{ ['--home-section-accent' as string]: accent }}
    >
      <header className="home-section__head">
        <p className="home-section__eyebrow">{eyebrow}</p>
        {accessory ? <div className="home-section__accessory">{accessory}</div> : null}
      </header>
      <div className="home-section__body">{children}</div>
    </section>
  );
}
