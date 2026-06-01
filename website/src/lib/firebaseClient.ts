import { initializeApp, getApps, getApp } from "firebase/app";
import { getAuth, GoogleAuthProvider, OAuthProvider, connectAuthEmulator } from "firebase/auth";
import { getFunctions, connectFunctionsEmulator } from "firebase/functions";

const firebaseConfig = {
  apiKey: import.meta.env.PUBLIC_FIREBASE_API_KEY || "AIzaSyFakeKeyPlaceholderForBuild",
  authDomain: import.meta.env.PUBLIC_FIREBASE_AUTH_DOMAIN || "burnbar.firebaseapp.com",
  projectId: import.meta.env.PUBLIC_FIREBASE_PROJECT_ID || "burnbar",
  storageBucket: import.meta.env.PUBLIC_FIREBASE_STORAGE_BUCKET || "burnbar.appspot.com",
  messagingSenderId: import.meta.env.PUBLIC_FIREBASE_MESSAGING_SENDER_ID || "123456789",
  appId: import.meta.env.PUBLIC_FIREBASE_APP_ID || "1:123456789:web:abcdef"
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
