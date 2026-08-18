"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import {
  onAuthStateChanged,
  signInWithCustomToken,
  signInWithPopup,
  signOut as fbSignOut,
  type User,
} from "firebase/auth";
import { startAuthentication, startRegistration } from "@simplewebauthn/browser";
import { auth, googleProvider, appleProvider, githubProvider } from "./firebaseClient";
import {
  beginPasskeyAssertion,
  registerPasskey,
  verifyPasskeyAssertion,
  verifyPasskeyRegistration,
} from "./api";
import { trackEvent, EVENT } from "./analytics";
import { bucketDurationMs } from "./analytics/buckets";

/** Auth sign-in methods, as the taxonomy's `method` enum (passkey is console-specific). */
type SignInMethod = "google" | "apple" | "github" | "passkey";

/**
 * Time a sign-in and emit `auth.sign_in.completed` with method + outcome +
 * bucketed duration. No PII, no tokens — just the enumerated method, success or
 * failure, and a coarse duration bucket. Dark until the member opts in.
 */
async function trackedSignIn(method: SignInMethod, fn: () => Promise<void>): Promise<void> {
  const startedAt = Date.now();
  try {
    await fn();
    trackEvent(EVENT.authSignInCompleted, {
      method,
      outcome: "success",
      duration_ms_bucket: bucketDurationMs(Date.now() - startedAt),
    });
  } catch (err) {
    trackEvent(EVENT.authSignInCompleted, {
      method,
      outcome: "failure",
      duration_ms_bucket: bucketDurationMs(Date.now() - startedAt),
    });
    throw err;
  }
}

interface AuthState {
  user: User | null;
  loading: boolean;
  signInGoogle: () => Promise<void>;
  signInApple: () => Promise<void>;
  signInGitHub: () => Promise<void>;
  signInPasskey: () => Promise<void>;
  createPasskey: () => Promise<string>;
  signOut: () => Promise<void>;
  passkeySupported: boolean;
  appleAuthEnabled: boolean;
  githubAuthEnabled: boolean;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const unsub = onAuthStateChanged(auth(), (u) => {
      setUser(u);
      setLoading(false);
    });
    return () => unsub();
  }, []);

  const signInGoogle = useCallback(async () => {
    await trackedSignIn("google", async () => {
      await signInWithPopup(auth(), googleProvider());
    });
  }, []);

  const signInApple = useCallback(async () => {
    await trackedSignIn("apple", async () => {
      await signInWithPopup(auth(), appleProvider());
    });
  }, []);

  const signInGitHub = useCallback(async () => {
    await trackedSignIn("github", async () => {
      await signInWithPopup(auth(), githubProvider());
    });
  }, []);

  const signInPasskey = useCallback(async () => {
    await trackedSignIn("passkey", async () => {
      if (typeof PublicKeyCredential === "undefined") {
        throw new Error("Passkeys are not supported in this browser.");
      }
      const { options } = await beginPasskeyAssertion();
      const assertion = await startAuthentication({ optionsJSON: options });
      const { token } = await verifyPasskeyAssertion(assertion, options.challenge);
      await signInWithCustomToken(auth(), token);
    });
  }, []);

  const createPasskey = useCallback(async () => {
    if (typeof PublicKeyCredential === "undefined") {
      throw new Error("Passkeys are not supported in this browser.");
    }
    try {
      const { options } = await registerPasskey();
      window.focus();
      await new Promise((resolve) => requestAnimationFrame(resolve));
      const response = await startRegistration({ optionsJSON: options });
      const { credentialId } = await verifyPasskeyRegistration(response, options.challenge);
      trackEvent(EVENT.passkeyEnrollmentCompleted, { outcome: "success" });
      return credentialId;
    } catch (err) {
      // Mirrors trackedSignIn: emit both outcomes so enrollment drop-off
      // (cancels, already-registered, verification failures) is visible.
      // No PII — just the enumerated outcome. Re-throw so the UI still
      // surfaces the (un-tracked) error text.
      trackEvent(EVENT.passkeyEnrollmentCompleted, { outcome: "failure" });
      throw err;
    }
  }, []);

  const signOut = useCallback(async () => {
    try {
      await fbSignOut(auth());
      trackEvent(EVENT.authSignedOut, { outcome: "success" });
    } catch (err) {
      trackEvent(EVENT.authSignedOut, { outcome: "failure" });
      throw err;
    }
  }, []);

  // WebAuthn support only exists client-side; computing it during render
  // (`typeof window !== "undefined"`) disagrees with the static prerender and
  // trips hydration. Start false everywhere, detect after mount.
  const [passkeySupported, setPasskeySupported] = useState(false);
  useEffect(() => {
    setPasskeySupported(typeof window.PublicKeyCredential !== "undefined");
  }, []);
  const appleAuthEnabled = process.env.NEXT_PUBLIC_ENABLE_APPLE_AUTH === "true";
  const githubAuthEnabled = process.env.NEXT_PUBLIC_ENABLE_GITHUB_AUTH === "true";

  const value = useMemo<AuthState>(
    () => ({
      user,
      loading,
      signInGoogle,
      signInApple,
      signInGitHub,
      signInPasskey,
      createPasskey,
      signOut,
      passkeySupported,
      appleAuthEnabled,
      githubAuthEnabled,
    }),
    [
      user,
      loading,
      signInGoogle,
      signInApple,
      signInGitHub,
      signInPasskey,
      createPasskey,
      signOut,
      passkeySupported,
      appleAuthEnabled,
      githubAuthEnabled,
    ],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within <AuthProvider>.");
  return ctx;
}
