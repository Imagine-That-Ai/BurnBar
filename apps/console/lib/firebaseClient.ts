/**
 * Firebase web client for app.burnbar.ai (the member console).
 *
 * Mirrors website/src/lib/firebaseClient.ts (same project, same region) and adds
 * App Check (reCAPTCHA Enterprise) because every console callable enforces App
 * Check. The defaults below are the project's PUBLIC client identifiers (Firebase
 * web config + reCAPTCHA Enterprise *site* key) — they are not secrets and ship
 * in every client bundle regardless; security is enforced server-side via App
 * Check tokens + Firestore rules. Committing them as defaults makes every build
 * (local AND CI, which has no `.env.production`) ship a working bundle. NEXT_PUBLIC_*
 * env still overrides them for staging/preview environments.
 */
import { initializeApp, getApps, getApp, type FirebaseApp } from "firebase/app";
import {
  getAuth,
  GoogleAuthProvider,
  OAuthProvider,
  connectAuthEmulator,
  type Auth,
} from "firebase/auth";
import { getFunctions, connectFunctionsEmulator, type Functions } from "firebase/functions";
import {
  initializeAppCheck,
  ReCaptchaEnterpriseProvider,
  type AppCheck,
} from "firebase/app-check";

// Public client identifiers (not secrets). Defaults are the production values so
// a build with no env (CI / fresh checkout) still ships a working bundle; env
// overrides win for staging/preview.
const firebaseConfig = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY || "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4",
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN || "app.burnbar.ai",
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID || "burnbar",
  storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET || "burnbar.firebasestorage.app",
  messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID || "246956661961",
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID || "1:246956661961:web:2e267f5d3a84a525480118",
};

// Public reCAPTCHA Enterprise SITE key (safe in the client; the secret key lives
// server-side). Defaulted so App Check initializes even without env.
const recaptchaSiteKey =
  process.env.NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY || "6Ld3bAktAAAAAABiZujpMLmUcvSMUPiJk6qENbOg";

const isBrowser = typeof window !== "undefined";

let _app: FirebaseApp | undefined;
let _auth: Auth | undefined;
let _functions: Functions | undefined;
let _appCheck: AppCheck | undefined;

export function firebaseApp(): FirebaseApp {
  if (_app) return _app;
  _app = getApps().length === 0 ? initializeApp(firebaseConfig) : getApp();

  // App Check — only in the browser, only when a site key is configured.
  if (isBrowser && !_appCheck) {
    const siteKey = recaptchaSiteKey;
    if (process.env.NODE_ENV !== "production") {
      const debugToken = process.env.NEXT_PUBLIC_APPCHECK_DEBUG_TOKEN;
      // Firebase reads this global to mint a debug App Check token in dev.
      (self as unknown as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string | boolean }).FIREBASE_APPCHECK_DEBUG_TOKEN =
        debugToken || true;
    }
    if (siteKey) {
      try {
        _appCheck = initializeAppCheck(_app, {
          provider: new ReCaptchaEnterpriseProvider(siteKey),
          isTokenAutoRefreshEnabled: true,
        });
      } catch {
        // Already initialised (HMR) or unsupported — degrade gracefully.
      }
    }
  }
  return _app;
}

export function auth(): Auth {
  if (_auth) return _auth;
  _auth = getAuth(firebaseApp());
  if (process.env.NODE_ENV !== "production" && isBrowser && !_auth.emulatorConfig) {
    try {
      connectAuthEmulator(_auth, "http://localhost:9099", { disableWarnings: true });
    } catch {
      /* HMR reconnect */
    }
  }
  return _auth;
}

export function functions(): Functions {
  if (_functions) return _functions;
  _functions = getFunctions(firebaseApp(), "us-central1");
  if (process.env.NODE_ENV !== "production" && isBrowser) {
    try {
      connectFunctionsEmulator(_functions, "localhost", 5001);
    } catch {
      /* HMR reconnect */
    }
  }
  return _functions;
}

export function googleProvider(): GoogleAuthProvider {
  return new GoogleAuthProvider();
}

export function appleProvider(): OAuthProvider {
  const provider = new OAuthProvider("apple.com");
  provider.addScope("email");
  provider.addScope("name");
  return provider;
}

export function githubProvider(): OAuthProvider {
  return new OAuthProvider("github.com");
}
