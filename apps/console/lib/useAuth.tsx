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
import { startAuthentication } from "@simplewebauthn/browser";
import { auth, googleProvider, appleProvider } from "./firebaseClient";
import { beginPasskeyAssertion, verifyPasskeyAssertion } from "./api";

interface AuthState {
  user: User | null;
  loading: boolean;
  signInGoogle: () => Promise<void>;
  signInApple: () => Promise<void>;
  signInPasskey: () => Promise<void>;
  signOut: () => Promise<void>;
  passkeySupported: boolean;
  appleAuthEnabled: boolean;
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

  const signInPasskey = useCallback(async () => {
    if (typeof PublicKeyCredential === "undefined") {
      throw new Error("Passkeys are not supported in this browser.");
    }
    const { options } = await beginPasskeyAssertion();
    const assertion = await startAuthentication({ optionsJSON: options });
    const { token } = await verifyPasskeyAssertion(assertion, options.challenge);
    await signInWithCustomToken(auth(), token);
  }, []);

  const signOut = useCallback(async () => {
    await fbSignOut(auth());
  }, []);

  const passkeySupported =
    typeof window !== "undefined" && typeof window.PublicKeyCredential !== "undefined";
  const appleAuthEnabled = process.env.NEXT_PUBLIC_ENABLE_APPLE_AUTH === "true";

  const value = useMemo<AuthState>(
    () => ({
      user,
      loading,
      signInGoogle,
      signInApple,
      signInPasskey,
      signOut,
      passkeySupported,
      appleAuthEnabled,
    }),
    [
      user,
      loading,
      signInGoogle,
      signInApple,
      signInPasskey,
      signOut,
      passkeySupported,
      appleAuthEnabled,
    ],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within <AuthProvider>.");
  return ctx;
}
