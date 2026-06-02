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
  signInWithPopup,
  signOut as fbSignOut,
  type User,
} from "firebase/auth";
import { auth, googleProvider, appleProvider } from "./firebaseClient";

interface AuthState {
  user: User | null;
  loading: boolean;
  signInGoogle: () => Promise<void>;
  signInApple: () => Promise<void>;
  signInPasskey: () => Promise<void>;
  signOut: () => Promise<void>;
  passkeySupported: boolean;
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
    await signInWithPopup(auth(), googleProvider());
  }, []);

  const signInApple = useCallback(async () => {
    await signInWithPopup(auth(), appleProvider());
  }, []);

  /**
   * Passkey-first sign-in. The WebAuthn assertion is exchanged for a Firebase
   * custom token by a server callable (see integration notes); until that
   * callable lands the UI keeps passkey primary but degrades to the federated
   * providers. We surface a typed error rather than a silent no-op.
   */
  const signInPasskey = useCallback(async () => {
    if (typeof PublicKeyCredential === "undefined") {
      throw new Error("Passkeys are not supported in this browser.");
    }
    throw new Error(
      "Passkey sign-in requires the verifyPasskeyAssertion callable (see integration notes). Use Google or Apple to continue.",
    );
  }, []);

  const signOut = useCallback(async () => {
    await fbSignOut(auth());
  }, []);

  const passkeySupported =
    typeof window !== "undefined" && typeof window.PublicKeyCredential !== "undefined";

  const value = useMemo<AuthState>(
    () => ({
      user,
      loading,
      signInGoogle,
      signInApple,
      signInPasskey,
      signOut,
      passkeySupported,
    }),
    [user, loading, signInGoogle, signInApple, signInPasskey, signOut, passkeySupported],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within <AuthProvider>.");
  return ctx;
}
