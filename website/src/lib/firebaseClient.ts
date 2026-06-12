import { initializeApp, getApps, getApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, OAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFunctions, connectFunctionsEmulator } from "firebase/functions";

// Public client identifiers (not secrets). Defaults are the production values for
// the "burnbar" Firebase project so a build with no env (CI, which has no
// .env.production) still ships a working sign-in bundle; env overrides win for
// staging/preview. These are the SAME public values used by apps/console
// (same Firebase project) — see apps/console/lib/firebaseClient.ts — except the
// website keeps its own authDomain/storageBucket (the console serves from
// app.burnbar.ai; the website uses the project's default firebaseapp.com domain,
// which is an authorized domain for signInWithPopup on burnbar.ai). Security is
// enforced server-side (Firestore rules + App Check), not by hiding these.
const firebaseConfig = {
  apiKey: import.meta.env.PUBLIC_FIREBASE_API_KEY || "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4",
  authDomain: import.meta.env.PUBLIC_FIREBASE_AUTH_DOMAIN || "burnbar.firebaseapp.com",
  projectId: import.meta.env.PUBLIC_FIREBASE_PROJECT_ID || "burnbar",
  storageBucket: import.meta.env.PUBLIC_FIREBASE_STORAGE_BUCKET || "burnbar.appspot.com",
  messagingSenderId: import.meta.env.PUBLIC_FIREBASE_MESSAGING_SENDER_ID || "246956661961",
  appId: import.meta.env.PUBLIC_FIREBASE_APP_ID || "1:246956661961:web:2e267f5d3a84a525480118"
};

const app = getApps().length === 0 ? initializeApp(firebaseConfig) : getApp();
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
