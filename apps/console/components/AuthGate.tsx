"use client";

import { useState } from "react";
import { KeyRound } from "lucide-react";
import { useAuth } from "@/lib/useAuth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { BrandMark } from "@/components/BrandMark";

/** Gate that shows the sign-in card until the member is authenticated. */
export function AuthGate({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();

  // Local preview only: render the app shell without auth. Inert in prod
  // builds unless NEXT_PUBLIC_PREVIEW_BYPASS_AUTH=1 is explicitly set.
  if (process.env.NEXT_PUBLIC_PREVIEW_BYPASS_AUTH === "1") return <>{children}</>;

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
  const { signInGoogle, signInApple, signInGitHub, signInPasskey, passkeySupported, appleAuthEnabled, githubAuthEnabled } =
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
      <Card className="signin-card w-full max-w-md text-center">
        <CardHeader className="items-center">
          <div className="mb-token-3">
            <BrandMark size={92} />
          </div>
          <CardTitle className="font-display text-[1.7rem] tracking-[-0.03em]">
            Your data, your keys
          </CardTitle>
          <CardDescription className="mx-auto max-w-xs">
            Sign in to see everything BurnBar holds for you — and take any of it back.
          </CardDescription>
        </CardHeader>
        <CardContent className="space-y-token-3">
          <div className="mx-auto w-full max-w-[280px] space-y-token-3">
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
              <img src="/brand/logos/google-g.svg" alt="" aria-hidden className="size-4 shrink-0" />
              {busy === "google" ? "…" : "Continue with Google"}
            </Button>
            {githubAuthEnabled && (
              <Button
                variant="secondary"
                className="w-full"
                onClick={wrap("github", signInGitHub)}
                disabled={!!busy}
              >
                <img
                  src="/brand/logos/github-mark.svg"
                  alt=""
                  aria-hidden
                  className="size-4 shrink-0"
                />
                {busy === "github" ? "…" : "Continue with GitHub"}
              </Button>
            )}
            {appleAuthEnabled && (
              <Button
                variant="secondary"
                className="w-full"
                onClick={wrap("apple", signInApple)}
                disabled={!!busy}
              >
                <svg
                  viewBox="0 0 24 24"
                  aria-hidden
                  className="size-4 shrink-0 -translate-y-px"
                  fill="currentColor"
                >
                  <path d="M17.05 12.04c-.03-2.7 2.2-3.99 2.3-4.05-1.25-1.83-3.2-2.08-3.9-2.11-1.66-.17-3.24.97-4.08.97-.84 0-2.14-.95-3.52-.92-1.81.03-3.48 1.05-4.41 2.67-1.88 3.27-.48 8.11 1.35 10.76.9 1.3 1.97 2.75 3.38 2.7 1.36-.05 1.87-.88 3.51-.88 1.64 0 2.1.88 3.53.85 1.46-.03 2.38-1.32 3.27-2.62 1.03-1.5 1.46-2.96 1.48-3.03-.03-.01-2.84-1.09-2.87-4.33zM14.38 4.36c.74-.9 1.24-2.15 1.1-3.4-1.07.04-2.36.71-3.13 1.61-.69.79-1.29 2.06-1.13 3.27 1.19.09 2.42-.6 3.16-1.48z" />
                </svg>
                {busy === "apple" ? "…" : "Continue with Apple"}
              </Button>
            )}
          </div>
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
