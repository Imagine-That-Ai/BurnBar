/** @type {import('next').NextConfig} */

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
  "connect-src 'self' https://apis.google.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net https://identitytoolkit.googleapis.com https://securetoken.googleapis.com https://firebaseinstallations.googleapis.com https://firebaseappcheck.googleapis.com https://content-firebaseappcheck.googleapis.com https://www.google.com https://www.gstatic.com",
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

export default nextConfig;
