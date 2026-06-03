"use client";

import { useState } from "react";
import { Flame, KeyRound } from "lucide-react";
import { useAuth } from "@/lib/useAuth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

/** Gate that shows the sign-in card until the member is authenticated. */
export function AuthGate({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();

  if (loading) {
    return (
      <div className="grid min-h-dvh place-items-center">
        <div className="size-8 animate-spin rounded-full border-2 border-mercury-wash border-t-brass-core" />
      </div>
    );
  }
  if (!user) return <SignInCard />;
  return <>{children}</>;
}

function SignInCard() {
  const { signInGoogle, signInApple, signInPasskey, passkeySupported, appleAuthEnabled } =
    useAuth();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const wrap = (name: string, fn: () => Promise<void>) => async () => {
    setBusy(name);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(signInErrorMessage(err));
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="grid min-h-dvh place-items-center px-token-4">
      <Card className="w-full max-w-md text-center">
        <CardHeader className="items-center">
          <Flame className="size-7 text-brass-core" />
          <CardTitle className="font-display text-2xl">Your data, your keys</CardTitle>
          <CardDescription>
            Sign in to see everything BurnBar holds for you — and take any of it back.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-3">
          {passkeySupported && (
            <Button className="w-full" onClick={wrap("passkey", signInPasskey)} disabled={!!busy}>
              <KeyRound className="size-4" />
              {busy === "passkey" ? "…" : "Sign in with a passkey"}
            </Button>
          )}
          <Button
            variant="secondary"
            className="w-full"
            onClick={wrap("google", signInGoogle)}
            disabled={!!busy}
          >
            {busy === "google" ? "…" : "Continue with Google"}
          </Button>
          {appleAuthEnabled && (
            <Button
              variant="secondary"
              className="w-full"
              onClick={wrap("apple", signInApple)}
              disabled={!!busy}
            >
              {busy === "apple" ? "…" : "Continue with Apple"}
            </Button>
          )}
          {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}
          <p className="pt-token-2 text-xs text-content-dim">
            {appleAuthEnabled
              ? "Passkeys are primary; Google and Apple are fallbacks."
              : "Passkeys work after setup; Google is the production fallback."}{" "}
            This page is private and never indexed.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}

function signInErrorMessage(err: unknown): string {
  const message = err instanceof Error ? err.message : "Sign-in failed.";
  if (
    message.includes("auth/operation-not-allowed") ||
    message.includes("CONFIGURATION_NOT_FOUND") ||
    message.includes("invalid_client")
  ) {
    return "This sign-in provider is not fully configured yet.";
  }
  if (
    message.includes("NotAllowedError") ||
    message.includes("privacy-considerations-client") ||
    message.includes("timed out or was not allowed")
  ) {
    return "No passkey was selected, or the passkey prompt was cancelled.";
  }
  return message;
}
