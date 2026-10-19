import { initializeApp, getApps, getApp } from "firebase/app";
import { initializeAppCheck, ReCaptchaEnterpriseProvider, type AppCheck } from "firebase/app-check";
import { getAuth, GoogleAuthProvider, OAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFunctions, connectFunctionsEmulator } from "firebase/functions";
import {
  apiKey,
  appId,
  messagingSenderId,
  projectId,
  recaptchaEnterpriseSiteKey,
  website
} from "../../../config/firebase-web-public.json";

// Public client identifiers (not secrets). The production "burnbar" values live in
// config/firebase-web-public.json, shared with apps/console and the one place to
// rotate them, so a build with no env (CI has no .env.production) still ships a
// working sign-in bundle; env overrides win for staging/preview, and the bundler
// drops a default an override replaces. The website keeps its own
// authDomain/storageBucket (the console serves from app.burnbar.ai; the website
// uses the project's default firebaseapp.com domain, which is an authorized
// domain for signInWithPopup on burnbar.ai). Security is enforced server-side
// (Firestore rules + App Check), not by hiding these.
// Exported so public, anonymous surfaces (e.g. the Arena vote page) can build
// a dedicated app instance without App Check — see bench-arena.ts.
//
// Environment isolation (BB-01): the production fallback above is legal ONLY
// for production builds. A build flagged PUBLIC_BURNBAR_ENV=staging|preview
// must never ship the "burnbar" project — so missing PUBLIC_FIREBASE_* env is
// a hard error, and so is an override that re-selects production. Vite replaces
// each import.meta.env.PUBLIC_* access at build time, so these checks are
// decided by the values baked into this bundle, not by whatever runs it later.
const burnbarEnvironment = import.meta.env.PUBLIC_BURNBAR_ENV || "production";
if (burnbarEnvironment === "staging" || burnbarEnvironment === "preview") {
  const missingEnv = [
    ["PUBLIC_FIREBASE_API_KEY", import.meta.env.PUBLIC_FIREBASE_API_KEY],
    ["PUBLIC_FIREBASE_AUTH_DOMAIN", import.meta.env.PUBLIC_FIREBASE_AUTH_DOMAIN],
    ["PUBLIC_FIREBASE_PROJECT_ID", import.meta.env.PUBLIC_FIREBASE_PROJECT_ID],
    ["PUBLIC_FIREBASE_STORAGE_BUCKET", import.meta.env.PUBLIC_FIREBASE_STORAGE_BUCKET],
    [
      "PUBLIC_FIREBASE_MESSAGING_SENDER_ID",
      import.meta.env.PUBLIC_FIREBASE_MESSAGING_SENDER_ID
    ],
    ["PUBLIC_FIREBASE_APP_ID", import.meta.env.PUBLIC_FIREBASE_APP_ID],
    ["PUBLIC_RECAPTCHA_ENTERPRISE_KEY", import.meta.env.PUBLIC_RECAPTCHA_ENTERPRISE_KEY]
  ]
    .filter(([, value]) => typeof value !== "string" || value.length === 0)
    .map(([name]) => name);
  if (missingEnv.length > 0) {
    throw new Error(
      `${burnbarEnvironment} build is missing ${missingEnv.join(", ")}. ` +
        'A non-production site must never fall back to the production "burnbar" Firebase project; ' +
        "build through website/scripts/build-staging.mjs."
    );
  }
  if (import.meta.env.PUBLIC_FIREBASE_PROJECT_ID === projectId) {
    throw new Error(
      `${burnbarEnvironment} build resolved PUBLIC_FIREBASE_PROJECT_ID="${projectId}" — ` +
        "the production project. Staging and preview must target burnbar-staging."
    );
  }
}

export const firebaseConfig = {
  apiKey: import.meta.env.PUBLIC_FIREBASE_API_KEY || apiKey,
  authDomain: import.meta.env.PUBLIC_FIREBASE_AUTH_DOMAIN || website.authDomain,
  projectId: import.meta.env.PUBLIC_FIREBASE_PROJECT_ID || projectId,
  storageBucket: import.meta.env.PUBLIC_FIREBASE_STORAGE_BUCKET || website.storageBucket,
  messagingSenderId: import.meta.env.PUBLIC_FIREBASE_MESSAGING_SENDER_ID || messagingSenderId,
  appId: import.meta.env.PUBLIC_FIREBASE_APP_ID || appId
};

const recaptchaSiteKey =
  import.meta.env.PUBLIC_RECAPTCHA_ENTERPRISE_KEY || recaptchaEnterpriseSiteKey;

const app = getApps().length === 0 ? initializeApp(firebaseConfig) : getApp();
let appCheck: AppCheck | undefined;

if (typeof window !== "undefined") {
  if (import.meta.env.DEV) {
    const debugToken = import.meta.env.PUBLIC_APPCHECK_DEBUG_TOKEN;
    (
      self as unknown as {
        FIREBASE_APPCHECK_DEBUG_TOKEN?: string | boolean;
      }
    ).FIREBASE_APPCHECK_DEBUG_TOKEN = debugToken || true;
  }
  try {
    appCheck = initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(recaptchaSiteKey),
      isTokenAutoRefreshEnabled: true
    });
  } catch {
    // HMR can re-evaluate the module after App Check has already initialized.
  }
}

export { appCheck };
export const auth = getAuth(app);
export const googleProvider = new GoogleAuthProvider();
export const appleProvider = new OAuthProvider("apple.com");
appleProvider.addScope("email");
appleProvider.addScope("name");
export const functions = getFunctions(app, "us-central1");

// Connect to emulators if in development mode
if (import.meta.env.DEV) {
  try {
    // connectAuthEmulator will throw if already connected (e.g. HMR)
    if (!auth.emulatorConfig) {
      connectAuthEmulator(auth, "http://localhost:9099", { disableWarnings: true });
      connectFunctionsEmulator(functions, "localhost", 5001);
      console.log("Connected to Firebase Auth & Functions Emulators.");
    }
  } catch {
    // Quietly catch HMR re-connect errors
  }
}
