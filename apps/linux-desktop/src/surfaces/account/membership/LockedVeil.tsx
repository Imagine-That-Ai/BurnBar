import { useEffect, useRef, type ReactNode } from 'react';
import { FoilButton } from './FoilButton.js';

export function LockedVeil({
  locked,
  title,
  detail,
  cta,
  onUnlock,
  children
}: {
  locked: boolean;
  title: string;
  detail: string;
  cta: string;
  onUnlock: () => void;
  children: ReactNode;
}) {
  const veiledRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!locked || typeof HTMLElement === 'undefined' || 'inert' in HTMLElement.prototype) return;
    const veiled = veiledRef.current;
    if (!veiled) return;
    const focusable = veiled.querySelectorAll<HTMLElement>(
      'a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])'
    );
    focusable.forEach((node) => {
      node.setAttribute('tabindex', '-1');
      node.setAttribute('aria-hidden', 'true');
    });
  }, [locked]);

  if (!locked) return <>{children}</>;

  return (
    <div className="membership-veil">
      <div
        ref={veiledRef}
        className="membership-veil-content"
        inert
        aria-hidden="true"
        tabIndex={-1}
        data-testid="membership-veiled-content"
      >
        {children}
      </div>
      <div className="membership-veil-panel" role="group" aria-label={title}>
        <div className="membership-lock-glyph" aria-hidden="true">
          <svg viewBox="0 0 24 24" focusable="false">
            <path
              d="M7 10V8a5 5 0 0 1 10 0v2m-9 0h8a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2v-6a2 2 0 0 1 2-2Z"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.7"
              strokeLinecap="round"
            />
          </svg>
        </div>
        <h3>{title}</h3>
        <p>{detail}</p>
        <FoilButton onClick={onUnlock}>{cta}</FoilButton>
      </div>
    </div>
  );
}
