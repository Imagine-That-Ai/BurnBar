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
  const { signInGoogle, signInApple, signInPasskey, passkeySupported } = useAuth();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const wrap = (name: string, fn: () => Promise<void>) => async () => {
    setBusy(name);
    setError(null);
    try {
      await fn();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Sign-in failed.");
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
          <Button
            variant="secondary"
            className="w-full"
            onClick={wrap("apple", signInApple)}
            disabled={!!busy}
          >
            {busy === "apple" ? "…" : "Continue with Apple"}
          </Button>
          {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}
          <p className="pt-token-2 text-xs text-content-dim">
            Passkeys are primary; Google and Apple are fallbacks. This page is private and never
            indexed.
          </p>
        </CardContent>
      </Card>
    </div>
  );
}
