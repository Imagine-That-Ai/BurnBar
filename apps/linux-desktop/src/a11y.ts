export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export function applyReducedMotionClass(): void {
  document.body.classList.toggle('reduced-motion', prefersReducedMotion());
}

/**
 * Pause all CSS animations while the window is hidden/minimized. WebKitGTK
 * keeps compositing infinite decorative animations (shimmer, skeleton pulse,
 * breathe) for windows nobody can see — under software rendering that is pure
 * CPU burn. Nothing is visible while hidden, so pausing has zero visual cost;
 * everything resumes on the next visibilitychange.
 */
export function wireHiddenAnimationPause(): void {
  const apply = () => {
    document.body.classList.toggle('app-hidden', document.hidden);
  };
  document.addEventListener('visibilitychange', apply);
  apply();
}