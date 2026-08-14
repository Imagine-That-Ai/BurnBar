import { at } from "./dom.js";
/**
 * Zoomable, pannable figures — one primitive for every chart, table and
 * infographic on the bench pages.
 *
 * The rule that shapes all of this: zooming must never lose your place.
 *
 *   - Zoom is anchored to the pointer (or the pinch midpoint), so the thing
 *     under your finger stays under your finger. Scaling about the element
 *     centre — the old behaviour — throws your reading position across the
 *     screen every time you zoom.
 *   - A plain scroll or a one-finger drag at 1× scrolls the *page*. A figure
 *     that swallows page scroll is the single most place-destroying thing a
 *     chart can do. Zoom is ⌘/Ctrl + scroll, pinch, the buttons, or a
 *     double-click; panning only takes over once you are actually zoomed in.
 *   - Expand uses the Fullscreen API and never scrolls the document, so
 *     closing it returns you exactly where you were.
 *
 * Markup contract:
 *   [data-fig]
 *     [data-fig-viewport]      the clipping window (focusable)
 *       [data-fig-stage]       the transformed content
 *     [data-fig-in|out|reset|expand]   optional controls
 *     [data-fig-level]         optional zoom readout
 *     [data-fig-hint]          optional "use ⌘ + scroll" nudge
 *
 * Transforms are applied through CSSOM, never inline style attributes, so the
 * hash-locked CSP stays lean.
 */

const MIN = 1;
const MAX = 6;
const STEP = 1.35;

const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

interface Figure {
  root: HTMLElement;
  viewport: HTMLElement;
  stage: HTMLElement;
  k: number;
  tx: number;
  ty: number;
}

/** Clamp the pan so the stage can never be dragged off into empty space. */
function clampPan(f: Figure): void {
  const vw = f.viewport.clientWidth;
  const vh = f.viewport.clientHeight;
  // The stage's un-scaled size — offsetWidth is unaffected by the transform.
  const sw = f.stage.offsetWidth * f.k;
  const sh = f.stage.offsetHeight * f.k;

  // Centre on any axis where the content is smaller than the window;
  // otherwise keep the edges inside.
  f.tx = sw <= vw ? (vw - sw) / 2 : Math.min(0, Math.max(vw - sw, f.tx));
  f.ty = sh <= vh ? (vh - sh) / 2 : Math.min(0, Math.max(vh - sh, f.ty));
}

function apply(f: Figure): void {
  clampPan(f);
  f.stage.style.transform = `translate(${f.tx.toFixed(2)}px, ${f.ty.toFixed(2)}px) scale(${f.k.toFixed(4)})`;

  const zoomed = f.k > MIN + 0.001;
  f.root.classList.toggle("is-zoomed", zoomed);

  // At 1× the page owns vertical gestures; zoomed in, the figure owns them.
  f.viewport.style.touchAction = zoomed ? "none" : "pan-y pinch-zoom";

  const level = f.root.querySelector<HTMLElement>("[data-fig-level]");
  if (level) level.textContent = `${Math.round(f.k * 100)}%`;

  for (const sel of ["[data-fig-out]", "[data-fig-reset]"]) {
    const btn = f.root.querySelector<HTMLButtonElement>(sel);
    if (btn) btn.disabled = !zoomed;
  }
  const inBtn = f.root.querySelector<HTMLButtonElement>("[data-fig-in]");
  if (inBtn) inBtn.disabled = f.k >= MAX - 0.001;

  f.viewport.setAttribute(
    "aria-label",
    zoomed
      ? `Figure, zoomed ${Math.round(f.k * 100)}%. Arrow keys pan, 0 resets.`
      : "Figure. Plus and minus zoom, arrow keys pan."
  );
}

/**
 * Zoom to `next`, keeping the content point currently under (px, py) — in
 * viewport coordinates — pinned under (px, py) afterwards. This is the whole
 * trick behind "zoom doesn't lose your place".
 */
function zoomAt(f: Figure, next: number, px: number, py: number): void {
  const k2 = Math.max(MIN, Math.min(MAX, next));
  if (Math.abs(k2 - f.k) < 0.0001) return;
  const cx = (px - f.tx) / f.k;
  const cy = (py - f.ty) / f.k;
  f.tx = px - cx * k2;
  f.ty = py - cy * k2;
  f.k = k2;
  apply(f);
}

/** Viewport-relative coordinates for a pointer/touch position. */
function local(f: Figure, clientX: number, clientY: number): [number, number] {
  const r = f.viewport.getBoundingClientRect();
  return [clientX - r.left, clientY - r.top];
}

function centreOf(f: Figure): [number, number] {
  return [f.viewport.clientWidth / 2, f.viewport.clientHeight / 2];
}

function reset(f: Figure): void {
  f.k = MIN;
  f.tx = 0;
  f.ty = 0;
  apply(f);
}

/** Briefly surface the "⌘ + scroll" hint when a plain wheel goes by. */
function flashHint(f: Figure): void {
  const hint = f.root.querySelector<HTMLElement>("[data-fig-hint]");
  if (!hint) return;
  hint.classList.add("is-on");
  window.clearTimeout(Number(hint.dataset.t ?? 0));
  hint.dataset.t = String(window.setTimeout(() => hint.classList.remove("is-on"), 1400));
}

function initFigure(root: HTMLElement): void {
  const viewport = root.querySelector<HTMLElement>("[data-fig-viewport]");
  const stage = root.querySelector<HTMLElement>("[data-fig-stage]");
  if (!viewport || !stage) return;

  const f: Figure = { root, viewport, stage, k: MIN, tx: 0, ty: 0 };
  apply(f);

  /* ── controls ──────────────────────────────────────────────────────── */

  root.querySelector("[data-fig-in]")?.addEventListener("click", () => {
    const [cx, cy] = centreOf(f);
    zoomAt(f, f.k * STEP, cx, cy);
  });
  root.querySelector("[data-fig-out]")?.addEventListener("click", () => {
    const [cx, cy] = centreOf(f);
    zoomAt(f, f.k / STEP, cx, cy);
  });
  root.querySelector("[data-fig-reset]")?.addEventListener("click", () => reset(f));

  /* ── expand ────────────────────────────────────────────────────────── */

  const expand = root.querySelector<HTMLButtonElement>("[data-fig-expand]");
  expand?.addEventListener("click", () => {
    if (document.fullscreenElement === root) {
      void document.exitFullscreen?.();
      return;
    }
    // Fullscreen never scrolls the document, so closing lands you exactly
    // where you were. The class fallback covers engines without the API.
    if (root.requestFullscreen) {
      void root.requestFullscreen().catch(() => root.classList.add("is-expanded"));
    } else {
      root.classList.toggle("is-expanded");
    }
  });

  document.addEventListener("fullscreenchange", () => {
    const on = document.fullscreenElement === root;
    root.classList.toggle("is-fullscreen", on);
    if (expand) expand.setAttribute("aria-pressed", String(on));
    // The viewport changes size in both directions; re-clamp so nothing
    // ends up stranded outside the window.
    requestAnimationFrame(() => apply(f));
  });

  // Escape leaves the CSS fallback too.
  root.addEventListener("keydown", (ev) => {
    if (ev.key === "Escape" && root.classList.contains("is-expanded")) {
      root.classList.remove("is-expanded");
      apply(f);
    }
  });

  /* ── wheel ─────────────────────────────────────────────────────────── */

  viewport.addEventListener(
    "wheel",
    (ev) => {
      // Trackpad pinch arrives as a wheel event with ctrlKey set.
      if (!ev.ctrlKey && !ev.metaKey) {
        if (f.k > MIN + 0.001) return; // zoomed in: let the drag handler pan
        flashHint(f);
        return; // 1×: the page keeps its scroll
      }
      ev.preventDefault();
      const [px, py] = local(f, ev.clientX, ev.clientY);
      zoomAt(f, f.k * Math.pow(0.995, ev.deltaY), px, py);
    },
    { passive: false }
  );

  /* ── double-click / double-tap ─────────────────────────────────────── */

  viewport.addEventListener("dblclick", (ev) => {
    const [px, py] = local(f, ev.clientX, ev.clientY);
    if (f.k > MIN + 0.001) reset(f);
    else zoomAt(f, 2.5, px, py);
  });

  /* ── mouse / pen drag ──────────────────────────────────────────────── */

  let dragging = false;
  let lastX = 0;
  let lastY = 0;

  viewport.addEventListener("pointerdown", (ev) => {
    if (ev.pointerType === "touch") return; // touch handled below
    if (f.k <= MIN + 0.001) return; // nothing to pan at 1×
    dragging = true;
    lastX = ev.clientX;
    lastY = ev.clientY;
    viewport.setPointerCapture(ev.pointerId);
    root.classList.add("is-grabbing");
  });

  viewport.addEventListener("pointermove", (ev) => {
    if (!dragging) return;
    f.tx += ev.clientX - lastX;
    f.ty += ev.clientY - lastY;
    lastX = ev.clientX;
    lastY = ev.clientY;
    apply(f);
  });

  const endDrag = (ev: PointerEvent): void => {
    if (!dragging) return;
    dragging = false;
    if (viewport.hasPointerCapture(ev.pointerId)) viewport.releasePointerCapture(ev.pointerId);
    root.classList.remove("is-grabbing");
  };
  viewport.addEventListener("pointerup", endDrag);
  viewport.addEventListener("pointercancel", endDrag);

  /* ── touch: one finger scrolls the page, two fingers zoom ──────────── */

  let pinchDist = 0;
  let pinchK = 1;
  let touchX = 0;
  let touchY = 0;

  const dist = (a: Touch, b: Touch): number =>
    Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);

  viewport.addEventListener(
    "touchstart",
    (ev) => {
      if (ev.touches.length === 2) {
        const [a, b] = [at(ev.touches, 0), at(ev.touches, 1)];
        pinchDist = dist(a, b);
        pinchK = f.k;
        [touchX, touchY] = local(f, (a.clientX + b.clientX) / 2, (a.clientY + b.clientY) / 2);
      } else if (ev.touches.length === 1 && f.k > MIN + 0.001) {
        const touch = at(ev.touches, 0);
        touchX = touch.clientX;
        touchY = touch.clientY;
      }
    },
    { passive: true }
  );

  viewport.addEventListener(
    "touchmove",
    (ev) => {
      if (ev.touches.length === 2 && pinchDist > 0) {
        ev.preventDefault();
        const [a, b] = [at(ev.touches, 0), at(ev.touches, 1)];
        const [mx, my] = local(f, (a.clientX + b.clientX) / 2, (a.clientY + b.clientY) / 2);
        // Follow the midpoint as it drifts, so a pinch can pan at the same time.
        f.tx += mx - touchX;
        f.ty += my - touchY;
        touchX = mx;
        touchY = my;
        zoomAt(f, pinchK * (dist(a, b) / pinchDist), mx, my);
        return;
      }

      // One finger: pan only when zoomed in. At 1× we stay out of the way and
      // the page scrolls normally.
      if (ev.touches.length === 1 && f.k > MIN + 0.001) {
        ev.preventDefault();
        const t = at(ev.touches, 0);
        f.tx += t.clientX - touchX;
        f.ty += t.clientY - touchY;
        touchX = t.clientX;
        touchY = t.clientY;
        apply(f);
      }
    },
    { passive: false }
  );

  viewport.addEventListener(
    "touchend",
    (ev) => {
      if (ev.touches.length < 2) pinchDist = 0;
      if (ev.touches.length === 1) {
        const touch = at(ev.touches, 0);
        touchX = touch.clientX;
        touchY = touch.clientY;
      }
    },
    { passive: true }
  );

  /* ── keyboard ──────────────────────────────────────────────────────── */

  viewport.addEventListener("keydown", (ev) => {
    const [cx, cy] = centreOf(f);
    const nudge = 48;
    switch (ev.key) {
      case "+":
      case "=":
        zoomAt(f, f.k * STEP, cx, cy);
        break;
      case "-":
      case "_":
        zoomAt(f, f.k / STEP, cx, cy);
        break;
      case "0":
        reset(f);
        break;
      case "ArrowLeft":
        f.tx += nudge;
        apply(f);
        break;
      case "ArrowRight":
        f.tx -= nudge;
        apply(f);
        break;
      case "ArrowUp":
        f.ty += nudge;
        apply(f);
        break;
      case "ArrowDown":
        f.ty -= nudge;
        apply(f);
        break;
      default:
        return;
    }
    ev.preventDefault();
  });

  /* Re-clamp when the window changes shape. */
  const ro = new ResizeObserver(() => apply(f));
  ro.observe(viewport);

  if (!reduced) stage.classList.add("ins-fig__stage--eased");
}

export function initFigures(root: ParentNode = document): void {
  root.querySelectorAll<HTMLElement>("[data-fig]").forEach(initFigure);
}
