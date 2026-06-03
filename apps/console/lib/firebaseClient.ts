/**
 * Firebase web client for app.burnbar.ai (the member console).
 *
 * Mirrors website/src/lib/firebaseClient.ts (same project, same region) and adds
 * App Check (reCAPTCHA Enterprise) because every console callable enforces App
 * Check. All values come from NEXT_PUBLIC_* env so no secrets are baked in; the
 * placeholders only exist so `next build` (which runs with no env) succeeds.
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

const firebaseConfig = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY || "AIzaSyFakeKeyPlaceholderForBuild",
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN || "app.burnbar.ai",
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID || "burnbar",
  storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET || "burnbar.appspot.com",
  messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID || "123456789",
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID || "1:123456789:web:abcdef",
};

const isBrowser = typeof window !== "undefined";
const productionEnvMissing =
  !process.env.NEXT_PUBLIC_FIREBASE_API_KEY ||
  !process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN ||
  !process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID ||
  !process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET ||
  !process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID ||
  !process.env.NEXT_PUBLIC_FIREBASE_APP_ID ||
  !process.env.NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY;

let _app: FirebaseApp | undefined;
let _auth: Auth | undefined;
let _functions: Functions | undefined;
let _appCheck: AppCheck | undefined;

export function firebaseApp(): FirebaseApp {
  if (_app) return _app;
  if (isBrowser && process.env.NODE_ENV === "production" && productionEnvMissing) {
    throw new Error("BurnBar console Firebase/App Check production environment is not configured.");
  }
  _app = getApps().length === 0 ? initializeApp(firebaseConfig) : getApp();

  // App Check — only in the browser, only when a site key is configured.
  if (isBrowser && !_appCheck) {
    const siteKey = process.env.NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY;
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
