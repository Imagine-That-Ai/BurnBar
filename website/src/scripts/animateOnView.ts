/**
 * animateOnView — tiny IntersectionObserver helper for /router.
 *
 * Adds `.is-visible` to every element marked `data-animate-onview` once it
 * crosses the viewport threshold. One observer, one pass, no framework.
 *
 * The CSS in the consuming component owns the actual animation; this script
 * only flips a class. That keeps the JS path small and the animation
 * vocabulary in CSS where motion tokens already live.
 *
 * Reduced-motion users: the consuming CSS short-circuits all loops; the
 * `.is-visible` class flip is still cheap, so we let it run.
 */

export function initAnimateOnView(): void {
  if (typeof window === "undefined") return;

  const targets = document.querySelectorAll<HTMLElement>("[data-animate-onview]");
  if (targets.length === 0) return;

  if (typeof IntersectionObserver === "undefined") {
    // No observer support — just reveal everything.
    targets.forEach((el) => el.classList.add("is-visible"));
    return;
  }

  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -8% 0px", threshold: 0.15 }
  );

  targets.forEach((el) => observer.observe(el));
}

if (typeof window !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => initAnimateOnView(), { once: true });
  } else {
    initAnimateOnView();
  }
}
