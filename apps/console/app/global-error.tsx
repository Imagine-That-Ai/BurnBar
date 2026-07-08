"use client";

/**
 * App-Router global error boundary for the BurnBar console.
 *
 * This is the LAST line of defense: it catches errors thrown in the root layout
 * itself (where a normal `error.tsx` cannot reach) and replaces the entire
 * document, so it renders its own <html>/<body> and cannot rely on the app's
 * providers, global CSS, or fonts having loaded. It reports the crash to Sentry
 * (a no-op when no DSN is configured) and shows an on-brand recovery screen.
 *
 * Before this existed, a crash in the console root was completely invisible and
 * left the member staring at a blank white page.
 */
import { useEffect } from "react";
import * as Sentry from "@sentry/nextjs";

export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    // Forward to Sentry. `beforeSend` (lib/sentry/scrub.ts) scrubs PII/secrets
    // from the event; this is a no-op when NEXT_PUBLIC_SENTRY_DSN is unset.
    Sentry.captureException(error);
  }, [error]);

  // Inline styles mirror the console's Pensieve tokens (paper #f6f4ef, ink text,
  // flame accent) because global CSS variables are not guaranteed here.
  return (
    <html lang="en">
      <head>
        <meta name="robots" content="noindex, nofollow, noarchive" />
        <title>Something went wrong — BurnBar Console</title>
      </head>
      <body
        style={{
          margin: 0,
          minHeight: "100vh",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          background: "#f6f4ef",
          color: "#1a1a19",
          fontFamily:
            '"Geist", -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif',
          WebkitFontSmoothing: "antialiased",
        }}
      >
        <main
          style={{
            maxWidth: "28rem",
            padding: "2.5rem",
            textAlign: "center",
          }}
        >
          <div
            aria-hidden
            style={{
              width: "3rem",
              height: "3rem",
              margin: "0 auto 1.5rem",
              borderRadius: "9999px",
              background: "rgba(244, 91, 105, 0.1)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "#b3243c",
              fontSize: "1.5rem",
              lineHeight: 1,
            }}
          >
            {/* Flame mark stand-in — the console's accent, no asset dependency. */}
            &#9650;
          </div>
          <h1
            style={{
              margin: "0 0 0.75rem",
              fontSize: "1.375rem",
              fontWeight: 600,
              letterSpacing: "-0.01em",
              fontFamily:
                '"Bricolage Grotesque", "Geist", -apple-system, system-ui, sans-serif',
            }}
          >
            Something went wrong
          </h1>
          <p
            style={{
              margin: "0 0 1.75rem",
              fontSize: "0.9375rem",
              lineHeight: 1.6,
              color: "#5a5a56",
            }}
          >
            The console hit an unexpected error. Your data is safe. Try again, and
            if it keeps happening, reload the page.
          </p>
          <button
            type="button"
            onClick={() => reset()}
            style={{
              appearance: "none",
              border: "1px solid #f45b69",
              background: "#f45b69",
              color: "#fffefb",
              fontSize: "0.9375rem",
              fontWeight: 600,
              padding: "0.625rem 1.25rem",
              borderRadius: "0.625rem",
              cursor: "pointer",
              fontFamily: "inherit",
            }}
          >
            Try again
          </button>
          {error.digest ? (
            <p
              style={{
                margin: "1.5rem 0 0",
                fontSize: "0.75rem",
                color: "#8a8a85",
                fontFamily: '"Geist Mono", "SF Mono", Menlo, Consolas, monospace',
              }}
            >
              Reference: {error.digest}
            </p>
          ) : null}
        </main>
      </body>
    </html>
  );
}
