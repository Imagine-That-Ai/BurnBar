/** @type {import('next').NextConfig} */
import { withSentryConfig } from "@sentry/nextjs";

// Strict CSP for the console. Firebase Auth + callables need their endpoints in
// connect-src; Firebase Auth's popup bridge loads apis.google.com, and
// reCAPTCHA Enterprise uses google.com/gstatic runtime calls for App Check.
// Auth popup/redirect uses frame-src for the IdP. WebAuthn needs no extra CSP
// (it is a browser API, not a network origin). 'wasm-unsafe-eval' is required
// by Firebase's internal use of WebAssembly in some SDK paths.
const csp = [
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  "img-src 'self' data: blob: https://*.googleusercontent.com",
  // Next.js injects inline runtime styles; styled tokens are static. Tailwind is built to a file.
  // Google Fonts stylesheet is loaded from fonts.googleapis.com (see app/layout.tsx).
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  // Next.js 15 emits a small inline bootstrap; 'wasm-unsafe-eval' covers Firebase SDK wasm.
  "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval' https://apis.google.com https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/",
  // Google Fonts webfont files come from fonts.gstatic.com.
  "font-src 'self' data: https://fonts.gstatic.com",
  // api2.amplitude.com (US) / api.eu.amplitude.com (EU) are the opt-in analytics
  // egress endpoints (Amplitude Browser SDK). They are only ever contacted AFTER
  // the member opts in; pre-consent the SDK is never loaded. The same origins
  // must also be present in firebase.json's `console` hosting target, since a
  // static export does not apply these next.config headers in production.
  "connect-src 'self' https://apis.google.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net https://identitytoolkit.googleapis.com https://securetoken.googleapis.com https://firebaseinstallations.googleapis.com https://firebaseappcheck.googleapis.com https://content-firebaseappcheck.googleapis.com https://www.google.com https://www.gstatic.com https://api2.amplitude.com https://api.eu.amplitude.com",
  "frame-src 'self' https://*.firebaseapp.com https://accounts.google.com https://appleid.apple.com https://www.google.com/recaptcha/",
  "frame-ancestors 'none'",
  "form-action 'self'",
  "upgrade-insecure-requests",
].join("; ");

const securityHeaders = [
  { key: "Content-Security-Policy", value: csp },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin-allow-popups" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Permissions-Policy",
    value:
      "accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=(), publickey-credentials-create=(self), publickey-credentials-get=(self)",
  },
  {
    key: "Strict-Transport-Security",
    value: "max-age=63072000; includeSubDomains; preload",
  },
  // The console is a private member surface — never index it.
  { key: "X-Robots-Tag", value: "noindex, nofollow, noarchive" },
];

const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  // Static export keeps this deployable to Firebase Hosting like the rest of the repo.
  output: "export",
  images: { unoptimized: true },
  // `output: export` does not run next.config headers in production hosting; the
  // equivalent CSP block is returned to the primary agent for firebase.json. We
  // still set headers here so `next dev` and any server runtime carry them.
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
};

// ── Sentry (observability) ────────────────────────────────────────────────────
// Wrap the Next config so client crashes on app.burnbar.ai are no longer
// invisible. Runtime init lives in instrumentation-client.ts / instrumentation.ts
// and is gated on NEXT_PUBLIC_SENTRY_DSN, so a no-DSN build is a clean no-op.
//
// Source-map upload is the only build-time Sentry behavior, and it is gated on a
// SENTRY_AUTH_TOKEN. CI runs `npm ci && next build` WITHOUT that token, so upload
// must stay disabled there or the build breaks; readable stack traces are a
// nice-to-have that the token unlocks when configured. `sentry.properties` is
// intentionally gitignored — all config comes from env, never a committed file.
const uploadSourceMaps = Boolean(process.env.SENTRY_AUTH_TOKEN);

const sentryBuildOptions = {
  org: process.env.SENTRY_ORG,
  project: process.env.SENTRY_PROJECT,
  authToken: process.env.SENTRY_AUTH_TOKEN,

  // Quiet unless in CI, matching functions' `silent: !process.env.CI` posture.
  silent: !process.env.CI,

  // Only upload source maps when a token is present; delete them from the client
  // bundle afterward so raw sources never ship to the browser.
  sourcemaps: {
    disable: !uploadSourceMaps,
    deleteSourcemapsAfterUpload: true,
  },

  // No tunnel route: the console is a static export with a strict CSP and no
  // server to proxy through. Ingest goes straight to the (allowlisted) DSN host.
  tunnelRoute: undefined,

  // Tree-shake Sentry's internal logger from the production bundle.
  disableLogger: true,

  // The console never registers a service worker; skip Sentry's SW injection.
  widenClientFileUpload: false,
};

// Only engage the Sentry build plugin when a DSN is configured. This keeps
// no-DSN local/CI builds byte-for-byte the plain Next output (no injected
// instrumentation, no build-time Sentry work).
export default process.env.NEXT_PUBLIC_SENTRY_DSN || process.env.SENTRY_DSN
  ? withSentryConfig(nextConfig, sentryBuildOptions)
  : nextConfig;
