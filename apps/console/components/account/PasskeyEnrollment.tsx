"use client";

import { useState, type MouseEvent, type ReactNode } from "react";
import { KeyRound, LoaderCircle } from "lucide-react";
import { Button, type ButtonProps } from "@/components/ui/button";
import { useAuth } from "@/lib/useAuth";
import { cn } from "@/lib/utils";

export function PasskeyEnrollmentActions({
  className,
  buttonClassName,
  buttonVariant = "primary",
  buttonSize = "md",
  secondaryAction,
}: {
  className?: string;
  buttonClassName?: string;
  buttonVariant?: ButtonProps["variant"];
  buttonSize?: ButtonProps["size"];
  secondaryAction?: ReactNode;
}) {
  const { createPasskey, passkeySupported } = useAuth();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleCreatePasskey = async (event: MouseEvent<HTMLButtonElement>) => {
    event.currentTarget.focus();
    window.focus();
    setBusy(true);
    setMessage(null);
    setError(null);
    try {
      await createPasskey();
      setMessage("Passkey created. Next sign-in can start from this browser or iCloud Keychain.");
    } catch (err) {
      setError(passkeySetupErrorMessage(err));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={cn("flex flex-col items-stretch gap-token-2", className)}>
      <Button
        type="button"
        variant={buttonVariant}
        size={buttonSize}
        className={buttonClassName}
        onClick={handleCreatePasskey}
        disabled={!passkeySupported || busy}
      >
        {busy ? (
          <LoaderCircle className="size-4 animate-spin" aria-hidden />
        ) : (
          <KeyRound className="size-4" aria-hidden />
        )}
        {busy ? "Creating..." : "Create a passkey"}
      </Button>
      {secondaryAction}
      {!passkeySupported && (
        <p className="text-xs leading-5 text-content-dim">
          This browser does not expose WebAuthn passkey creation.
        </p>
      )}
      {message && <p className="text-xs leading-5 text-content-mute">{message}</p>}
      {error && (
        <p className="text-xs leading-5 text-[color:var(--color-seal-crimson)]">{error}</p>
      )}
    </div>
  );
}

export function PasskeyEnrollmentCard({ className }: { className?: string }) {
  return (
    <section className={cn("glass-pane p-token-5", className)} aria-labelledby="passkey-heading">
      <div className="mb-token-4 flex items-start gap-token-3">
        <div
          className="grid size-10 place-items-center border border-glass-line bg-mercury-wash"
          aria-hidden
        >
          <KeyRound className="size-4 text-[color:var(--accent)]" />
        </div>
        <div>
          <p className="eyebrow eyebrow--accent">Passkey sign-in</p>
          <h2 id="passkey-heading" className="mt-1 text-2xl tracking-[-0.02em]">
            Add a passkey to this account.
          </h2>
          <p className="mt-token-2 text-sm leading-6 text-content-mute">
            Use Apple or Google once, create a passkey here, then future sign-ins can start from
            the passkey button on the sign-in screen.
          </p>
        </div>
      </div>

      <PasskeyEnrollmentActions buttonClassName="h-11 px-token-5 text-sm" />
    </section>
  );
}

export function passkeySetupErrorMessage(err: unknown): string {
  const message = err instanceof Error ? err.message : "Passkey setup failed.";
  if (
    message.includes("InvalidStateError") ||
    message.includes("excluded by the excludeCredentials")
  ) {
    return "A passkey is already registered for this account on this authenticator.";
  }
  if (
    message.includes("NotAllowedError") ||
    message.includes("privacy-considerations-client") ||
    message.includes("timed out or was not allowed")
  ) {
    return "Passkey setup was cancelled.";
  }
  if (message.includes("document is not focused")) {
    return "Safari needs the page focused before passkey setup. Click the page once, then create the passkey again.";
  }
  return message;
}
