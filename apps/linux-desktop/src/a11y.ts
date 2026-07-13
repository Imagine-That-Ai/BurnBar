export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/**
 * Keep the CSS and JS motion gates aligned for the lifetime of the window.
 * Desktop accessibility settings can change while the app remains open; a
 * startup-only class would leave canvas/pet timing on the old preference.
 */
export function applyReducedMotionClass(): () => void {
  const query = window.matchMedia('(prefers-reduced-motion: reduce)');
  const apply = () => document.body?.classList.toggle('reduced-motion', query.matches);
  apply();

  const onChange = () => apply();
  if (typeof query.addEventListener === 'function') {
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }

  // Safari/WebKitGTK versions predating MediaQueryListEvent support expose
  // the legacy listener pair instead.
  query.addListener(onChange);
  return () => query.removeListener(onChange);
}
