/**
 * atmosphere.ts — tie the fixed background canvases to page position.
 *
 * #bgCanvas and #bgDots are position:fixed, so CSS alone cannot make them
 * behave like part of the page: a mask is relative to the viewport, which
 * means it travels down the document and re-reveals the field over whatever
 * the reader is trying to read. This writes the one thing CSS can't derive —
 * scroll position — into `--atmo`, and globals.css does the rest.
 *
 * The field is at full strength over the hero and gone by the time the reader
 * is into the page. It is atmosphere for the top of a page, not wallpaper for
 * all of it.
 *
 * Started as a bench-page local (bench-instrument.ts's initAtmosphere) and
 * promoted here so every page shares one backdrop.
 */

/** Peak opacity, over the hero. Matches the `--atmo` default in globals.css,
 *  which covers first paint before this module runs. */
const PEAK = 0.32;

/** Fraction of a viewport height the fade is spread over. */
const FADE_SPAN = 0.72;

function initAtmosphere(): void {
  // Reduced motion keeps the static painted frame at its resting value rather
  // than animating opacity against the scroll. The canvas scripts paint a
  // still frame in that mode; this leaves it alone.
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const root = document.documentElement;
  let queued = false;

  const update = (): void => {
    queued = false;
    // A zero-height viewport (headless capture, a display:none iframe) would
    // make this 0/0 and write NaN, dropping the field entirely. No viewport
    // means nothing has scrolled.
    const span = window.innerHeight * FADE_SPAN;
    const fade = span > 0 ? Math.min(1, window.scrollY / span) : 0;
    root.style.setProperty("--atmo", (PEAK * (1 - fade)).toFixed(3));
  };

  const schedule = (): void => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(update);
  };

  // Resize matters as much as scroll: the fade is measured in viewport
  // heights, so a rotation or a window drag changes where the field lands.
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule, { passive: true });
  update();
}

initAtmosphere();
