export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export function prefersReducedTransparency(): boolean {
  return window.matchMedia('(prefers-reduced-transparency: reduce)').matches;
}

function applyMediaPreferenceClass(mediaQuery: string, className: string): () => void {
  const query = window.matchMedia(mediaQuery);
  const apply = () => document.body?.classList.toggle(className, query.matches);
  apply();

  const onChange = () => apply();
  if (typeof query.addEventListener === 'function') {
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }

  // WebKitGTK versions predating MediaQueryListEvent support expose the
  // legacy listener pair instead.
  query.addListener(onChange);
  return () => query.removeListener(onChange);
}

/**
 * Keep the CSS and JS motion gates aligned for the lifetime of the window.
 * Desktop accessibility settings can change while the app remains open; a
 * startup-only class would leave canvas/pet timing on the old preference.
 */
export function applyReducedMotionClass(): () => void {
  return applyMediaPreferenceClass('(prefers-reduced-motion: reduce)', 'reduced-motion');
}

/**
 * Keep Liquid Glass fallbacks aligned with the desktop's Reduce Transparency
 * setting for the lifetime of the window, including live preference changes.
 */
export function applyReducedTransparencyClass(): () => void {
  return applyMediaPreferenceClass('(prefers-reduced-transparency: reduce)', 'reduced-transparency');
}
