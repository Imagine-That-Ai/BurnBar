/**
 * Firebase web client for app.burnbar.ai (the member console).
 *
 * Mirrors website/src/lib/firebaseClient.ts (same project, same region) and adds
 * App Check (reCAPTCHA Enterprise) because every console callable enforces App
 * Check. The defaults come from config/firebase-web-public.json, the project's
 * PUBLIC client identifiers (Firebase web config + reCAPTCHA Enterprise *site*
 * key) shared with the website — they are not secrets and ship in every client
 * bundle regardless; security is enforced server-side via App Check tokens +
 * Firestore rules. Reading them from that one reviewed file makes every build
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
import { getFirestore, connectFirestoreEmulator, type Firestore } from "firebase/firestore";
import {
  initializeAppCheck,
  ReCaptchaEnterpriseProvider,
  type AppCheck,
} from "firebase/app-check";
import firebaseWebPublic from "../../../config/firebase-web-public.json";

// Public client identifiers (not secrets). Defaults are the production values so
// a build with no env (CI / fresh checkout) still ships a working bundle; env
// overrides win for staging/preview.
//
// Environment isolation (BB-01/BB-12): the production fallback is legal ONLY
// for production builds. A console build flagged NEXT_PUBLIC_BURNBAR_ENV=
// staging|preview must never ship the "burnbar" project — missing
// NEXT_PUBLIC_FIREBASE_* env, or an override that re-selects production, is a
// hard error instead of a silent prod-bound bundle.
const burnbarEnvironment = process.env.NEXT_PUBLIC_BURNBAR_ENV || "production";
if (burnbarEnvironment === "staging" || burnbarEnvironment === "preview") {
  const missingEnv = [
    ["NEXT_PUBLIC_FIREBASE_API_KEY", process.env.NEXT_PUBLIC_FIREBASE_API_KEY],
    ["NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN", process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN],
    ["NEXT_PUBLIC_FIREBASE_PROJECT_ID", process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID],
    [
      "NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET",
      process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET
    ],
    [
      "NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID",
      process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID
    ],
    ["NEXT_PUBLIC_FIREBASE_APP_ID", process.env.NEXT_PUBLIC_FIREBASE_APP_ID],
    [
      "NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY",
      process.env.NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY
    ]
  ]
    .filter(([, value]) => typeof value !== "string" || value.length === 0)
    .map(([name]) => name);
  if (missingEnv.length > 0) {
    throw new Error(
      `${burnbarEnvironment} console build is missing ${missingEnv.join(", ")}. ` +
        'A non-production console must never fall back to the production "burnbar" Firebase project.'
    );
  }
  if (process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID === firebaseWebPublic.projectId) {
    throw new Error(
      `${burnbarEnvironment} console build resolved NEXT_PUBLIC_FIREBASE_PROJECT_ID="${firebaseWebPublic.projectId}" — ` +
        "the production project. Staging and preview must target burnbar-staging."
    );
  }
}

const firebaseConfig = {
  apiKey: process.env.NEXT_PUBLIC_FIREBASE_API_KEY || firebaseWebPublic.apiKey,
  authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN || firebaseWebPublic.console.authDomain,
  projectId: process.env.NEXT_PUBLIC_FIREBASE_PROJECT_ID || firebaseWebPublic.projectId,
  storageBucket: process.env.NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET || firebaseWebPublic.console.storageBucket,
  messagingSenderId: process.env.NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID || firebaseWebPublic.messagingSenderId,
  appId: process.env.NEXT_PUBLIC_FIREBASE_APP_ID || firebaseWebPublic.appId,
};

// Public reCAPTCHA Enterprise SITE key (safe in the client; the secret key lives
// server-side). Defaulted so App Check initializes even without env.
const recaptchaSiteKey = process.env.NEXT_PUBLIC_RECAPTCHA_ENTERPRISE_KEY || firebaseWebPublic.recaptchaEnterpriseSiteKey;

const isBrowser = typeof window !== "undefined";

// Dev defaults to the local Firebase emulator suite. Set
// NEXT_PUBLIC_FIREBASE_EMULATORS=0 to point a dev build at the real project
// instead (e.g. previewing against live data without running emulators).
const useEmulators =
  process.env.NODE_ENV !== "production" && process.env.NEXT_PUBLIC_FIREBASE_EMULATORS !== "0";

let _app: FirebaseApp | undefined;
let _auth: Auth | undefined;
let _functions: Functions | undefined;
let _db: Firestore | undefined;
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
  if (useEmulators && isBrowser && !_auth.emulatorConfig) {
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
  if (useEmulators && isBrowser) {
    try {
      connectFunctionsEmulator(_functions, "localhost", 5001);
    } catch {
      /* HMR reconnect */
    }
  }
  return _functions;
}

export function db(): Firestore {
  if (_db) return _db;
  _db = getFirestore(firebaseApp());
  if (useEmulators && isBrowser) {
    try {
      connectFirestoreEmulator(_db, "localhost", 8080);
    } catch {
      /* HMR reconnect */
    }
  }
  return _db;
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
