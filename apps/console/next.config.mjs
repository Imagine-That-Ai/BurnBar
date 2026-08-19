/** @type {import('next').NextConfig} */

// In development the Next client runtime (webpack HMR / react-refresh)
// executes modules via eval(), so script-src needs 'unsafe-eval' locally.
// Production is a static export served by Firebase Hosting with its own strict
// CSP in firebase.json (no 'unsafe-eval') — this relaxes DEV ONLY.
const isDev = process.env.NODE_ENV === "development";

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
  // 'unsafe-eval' is dev-only (see isDev above) — never ship it in production.
  `script-src 'self' 'unsafe-inline' ${isDev ? "'unsafe-eval' " : ""}'wasm-unsafe-eval' https://apis.google.com https://www.google.com/recaptcha/ https://www.gstatic.com/recaptcha/`,
  // Google Fonts webfont files come from fonts.gstatic.com.
  "font-src 'self' data: https://fonts.gstatic.com",
  // api2.amplitude.com (US) / api.eu.amplitude.com (EU) are the opt-in analytics
  // egress endpoints. Sentry ingest origins are direct browser crash-report
  // endpoints when NEXT_PUBLIC_SENTRY_DSN is configured. The same origins must
  // also be present in firebase.json's `console` hosting target, since a static
  // export does not apply these next.config headers in production.
  "connect-src 'self' https://apis.google.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net https://identitytoolkit.googleapis.com https://securetoken.googleapis.com https://firebaseinstallations.googleapis.com https://firebaseappcheck.googleapis.com https://content-firebaseappcheck.googleapis.com https://www.google.com https://www.gstatic.com https://api2.amplitude.com https://api.eu.amplitude.com https://*.ingest.sentry.io https://*.ingest.us.sentry.io",
  // app.burnbar.ai in frame-src: in local dev the origin is localhost, so the
  // Firebase Auth helper iframe (custom authDomain) is cross-origin and must be
  // explicitly allowed — without it popup sign-in hangs, then dies with
  // auth/popup-closed-by-user. Same-origin in prod, where 'self' already covers it.
  "frame-src 'self' https://*.firebaseapp.com https://app.burnbar.ai https://accounts.google.com https://appleid.apple.com https://www.google.com/recaptcha/",
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
// Runtime init lives in instrumentation-client.ts / instrumentation.ts and is
// gated on NEXT_PUBLIC_SENTRY_DSN, so a no-DSN build is a clean no-op. We do not
// use the Next Sentry build wrapper here: it pulls in the Sentry CLI package,
// whose source-available license is intentionally blocked by dependency review.
export default nextConfig;
