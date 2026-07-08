export function prefersReducedMotion(): boolean {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
}

export function applyReducedMotionClass(): void {
  document.body.classList.toggle('reduced-motion', prefersReducedMotion());
}