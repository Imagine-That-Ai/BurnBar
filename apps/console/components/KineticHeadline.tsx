"use client";

import * as React from "react";
import { prepareWithSegments, layoutWithLines } from "@chenglou/pretext";

import { inkFor } from "@/lib/kernelInk";
import { useBackdrop } from "@/lib/useBackdrop";

type Props = {
  text: string;
  /** className applied to the heading (carry the existing hero type styles). */
  className?: string;
  /** Optional explicit CSS font shorthand; default = the element's computed font. */
  font?: string;
  as?: "h1" | "h2";
  style?: React.CSSProperties;
};

type Line = { words: string[] };

// useLayoutEffect on the server emits a dev warning; fall back to useEffect there.
// (Effects never actually run during SSR — this only silences the warning.)
const useIsoLayoutEffect =
  typeof window !== "undefined" ? React.useLayoutEffect : React.useEffect;

/** Deterministic 0..1 from an index — keeps shatter scatter stable SSR↔CSR. */
function seeded(i: number): number {
  return ((i * 9301 + 49297) % 233280) / 233280;
}

/**
 * Lay `text` out into the exact lines the browser would wrap, using Pretext's
 * font-accurate measurement at `width`. The returned line breaks then become
 * hard `display:block` breaks on the spans, so the kinetic headline's wrapping
 * is deterministic and never shifts when the webfont finishes loading.
 */
function splitLines(text: string, font: string, width: number): Line[] {
  try {
    const prepared = prepareWithSegments(text, font);
    const lineHeight = parseFloat(font.match(/(\d*\.?\d+)px/)?.[1] ?? "") || 64;
    const { lines } = layoutWithLines(prepared, width, lineHeight);
    if (lines?.length) {
      return lines.map((l) => ({
        words: l.text.trim().split(/\s+/).filter(Boolean),
      }));
    }
  } catch {
    /* measurement unavailable — fall through to a single line */
  }
  return [{ words: text.trim().split(/\s+/).filter(Boolean) }];
}

/**
 * Pretext-driven kinetic headline.
 *
 * SSR-safe & accessible: the server (and the no-JS / reduced-motion / non-ink
 * path) renders the plain string inside the real heading — correct first paint,
 * SEO, and screen-reader text with zero canvas. On mount, on an ink route, with
 * motion allowed, it measures the live computed font, lays the copy out into the
 * browser's own line breaks via Pretext, splits into per-word / per-glyph spans
 * (granularity from the active kernel's `timing.unit`), and plays that kernel's
 * entrance. Measurement is synchronous inside a layout effect, so the entrance
 * starts from its first frame with no plain-text flash and no layout shift. The
 * universal `--ink-halo` text-shadow (inherited from `body[data-ink]`) keeps
 * every glyph legible mid-flight.
 */
export function KineticHeadline({ text, className, font, as = "h1", style }: Props) {
  const Tag = as;
  const { kernelId, inkEnabled } = useBackdrop();
  const ink = inkFor(kernelId);
  const ref = React.useRef<HTMLHeadingElement>(null);
  const [lines, setLines] = React.useState<Line[] | null>(null);
  const [play, setPlay] = React.useState(false);
  // Last committed wrapping key — guards against redundant re-splits/replays.
  const lastKeyRef = React.useRef<string | null>(null);

  // Measure → split → arm, synchronously before paint. Re-split on resize.
  useIsoLayoutEffect(() => {
    const el = ref.current;
    if (!el || !inkEnabled) return;

    // A real text/font/route change must force a fresh split + entrance.
    lastKeyRef.current = null;

    // Respect reduced motion: never split → the plain-text branch renders.
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      setLines(null);
      setPlay(false);
      return;
    }

    const measure = () => {
      const cs = getComputedStyle(el);
      const f = font ?? `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`;
      const width = el.clientWidth || el.getBoundingClientRect().width;
      const next = splitLines(text, f, Math.max(120, width));
      // Only commit when the wrapping actually changed. The ResizeObserver's
      // initial callback and the fonts-ready re-measure usually reproduce the
      // same split — committing a fresh array each time would re-arm and replay
      // the entrance. A genuine reflow changes the key → one deliberate replay.
      const key = next.map((l) => l.words.join("\u0001")).join("\u0002");
      if (key === lastKeyRef.current) return;
      lastKeyRef.current = key;
      setLines(next);
    };

    measure();

    // Webfont metrics can refine after load; re-measure once fonts are ready so
    // the split matches the rendered face (only meaningfully differs pre-load).
    let cancelled = false;
    void (document.fonts?.ready ?? Promise.resolve()).then(() => {
      if (!cancelled) measure();
    });

    // Re-split on width changes (a deliberate relayout replays the entrance).
    let raf = 0;
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(measure);
    });
    ro.observe(el);
    return () => {
      cancelled = true;
      ro.disconnect();
      cancelAnimationFrame(raf);
    };
  }, [text, font, inkEnabled]);

  // Start motion the frame after the armed spans commit, so the from-state paints.
  React.useEffect(() => {
    if (!lines) {
      setPlay(false);
      return;
    }
    setPlay(false);
    const id = requestAnimationFrame(() => setPlay(true));
    return () => cancelAnimationFrame(id);
  }, [lines]);

  // SSR + no-ink + reduced-motion fallback: plain, fully-styled, accessible text.
  if (!inkEnabled || lines === null) {
    return (
      <Tag ref={ref} className={className} style={style}>
        {text}
      </Tag>
    );
  }

  const { dur, stagger, ease, unit } = ink.timing;
  let idx = 0; // running unit index → a single global stagger across all lines

  return (
    <Tag
      ref={ref}
      className={className}
      data-kinetic={play ? ink.motion : "armed"}
      style={{
        ...style,
        ["--kin-dur" as string]: `${dur}ms`,
        ["--kin-ease" as string]: ease,
      }}
      aria-label={text}
    >
      {lines.map((line, li) => (
        <span key={li} className="kin-line" aria-hidden>
          {line.words.map((word, wi) => (
            <React.Fragment key={wi}>
              <span className="kin-word">
                {unit === "glyph"
                  ? [...word].map((g, gi) => {
                      const i = idx++;
                      return (
                        <span
                          key={gi}
                          className="kin-unit"
                          style={{
                            animationDelay: `${i * stagger}ms`,
                            ["--kin-rand" as string]: seeded(i),
                          }}
                        >
                          {g}
                        </span>
                      );
                    })
                  : (() => {
                      const i = idx++;
                      return (
                        <span
                          className="kin-unit"
                          style={{
                            animationDelay: `${i * stagger}ms`,
                            ["--kin-rand" as string]: seeded(i),
                          }}
                        >
                          {word}
                        </span>
                      );
                    })()}
              </span>
              {wi < line.words.length - 1 ? " " : null}
            </React.Fragment>
          ))}
        </span>
      ))}
    </Tag>
  );
}
