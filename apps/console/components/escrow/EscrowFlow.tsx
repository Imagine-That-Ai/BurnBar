"use client";

import { useCallback, useState } from "react";
import { Lock, ShieldCheck, RefreshCw, CheckCircle2 } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import {
  getOrCreateDeviceKeyPair,
  exportDevicePublicJwk,
  importVaultKey,
  unwrapVaultKeyBytes,
  base64ToBytes,
  webAuthnPrfSupported,
  EscrowError,
} from "@/lib/escrow";
import { registerBrowserEscrowDevice } from "@/lib/api";

type Step = "idle" | "registering" | "pending" | "unwrapping" | "ready" | "error";

/**
 * Browser escrow trust flow:
 *  1. Generate / load the non-extractable device key pair (IndexedDB).
 *  2. registerBrowserEscrowDevice(publicKeyJwk, recaptchaToken) -> status:"pending".
 *  3. The user approves on a trusted NATIVE device (approveEscrowDeviceTrust),
 *     which mints a cloud_vault_key_wrapper for this browser device.
 *  4. We poll, fetch the wrapper, unwrap the vault key in-memory, and hold the
 *     non-extractable AES-GCM CryptoKey to decrypt sealed content on demand.
 *
 * The vault key never leaves this tab's memory and is never serialised.
 */
export function EscrowFlow({
  fetchWrappedKey,
  onVaultKeyReady,
}: {
  /** Resolves the wrapped-key base64 once the native device approves (else null). */
  fetchWrappedKey: (escrowDeviceId: string) => Promise<string | null>;
  /** Called once with the in-memory vault key and raw key bytes for local-only cloak/decrypt work. */
  onVaultKeyReady?: (vaultKey: CryptoKey, rawVaultKey: Uint8Array) => void;
}) {
  const [step, setStep] = useState<Step>("idle");
  const [error, setError] = useState<string | null>(null);
  const [escrowDeviceId, setEscrowDeviceId] = useState<string | null>(null);

  const register = useCallback(async () => {
    setStep("registering");
    setError(null);
    try {
      const pair = await getOrCreateDeviceKeyPair();
      const jwk = await exportDevicePublicJwk(pair);
      const res = await registerBrowserEscrowDevice(jwk);
      setEscrowDeviceId(res.escrowDeviceId);
      setStep("pending");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not register this browser.");
      setStep("error");
    }
  }, []);

  const poll = useCallback(async () => {
    if (!escrowDeviceId) return;
    setError(null);
    try {
      const wrappedB64 = await fetchWrappedKey(escrowDeviceId);
      if (!wrappedB64) {
        // Still pending — leave the UI on the pending step.
        return;
      }
      setStep("unwrapping");
      const pair = await getOrCreateDeviceKeyPair();
      const rawVaultKey = await unwrapVaultKeyBytes(base64ToBytes(wrappedB64), pair.privateKey);
      const vaultKey = await importVaultKey(rawVaultKey);
      onVaultKeyReady?.(vaultKey, rawVaultKey);
      setStep("ready");
    } catch (err) {
      if (err instanceof EscrowError) setError(err.message);
      else setError(err instanceof Error ? err.message : "Could not unwrap the vault key.");
      setStep("error");
    }
  }, [escrowDeviceId, fetchWrappedKey, onVaultKeyReady]);

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-token-2">
          <Lock className="size-4 text-tier-end-to-end" />
          Decrypt in this browser
        </CardTitle>
        <CardDescription>
          To read end-to-end sealed content here, this browser must be trusted by one of your
          existing devices. The vault key is unwrapped in memory only — BurnBar never sees it.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-token-4">
        <ol className="space-y-token-3 text-sm">
          <StepRow
            active={step === "idle" || step === "registering"}
            done={step !== "idle" && step !== "registering"}
            icon={<ShieldCheck className="size-4" />}
            title="Register this browser"
            detail="Generates a non-extractable device key and asks your account to trust it."
          />
          <StepRow
            active={step === "pending"}
            done={step === "unwrapping" || step === "ready"}
            icon={<RefreshCw className="size-4" />}
            title="Approve on a trusted device"
            detail="Open BurnBar on your Mac or phone and approve this browser. Then check for approval."
          />
          <StepRow
            active={step === "unwrapping"}
            done={step === "ready"}
            icon={<CheckCircle2 className="size-4" />}
            title="Unwrap the vault key"
            detail="Decrypts the wrapped key locally so sealed content opens in this tab."
          />
        </ol>

        {error && <p className="text-xs text-[color:var(--color-seal-crimson)]">{error}</p>}

        <div className="flex flex-wrap gap-token-2">
          {(step === "idle" || step === "error") && (
            <Button onClick={register}>Register this browser</Button>
          )}
          {step === "registering" && <Button disabled>Registering…</Button>}
          {step === "pending" && (
            <Button variant="secondary" onClick={poll}>
              <RefreshCw className="size-3.5" />
              Check for approval
            </Button>
          )}
          {step === "unwrapping" && <Button disabled>Unwrapping…</Button>}
          {step === "ready" && (
            <p className="flex items-center gap-token-2 text-sm text-tier-end-to-end">
              <CheckCircle2 className="size-4" />
              This browser can now decrypt your sealed content.
            </p>
          )}
        </div>

        {webAuthnPrfSupported() && step === "idle" && (
          <p className="text-xs text-content-dim">
            Your passkey can additionally gate this browser&apos;s decrypt key (WebAuthn PRF).
          </p>
        )}
      </CardContent>
    </Card>
  );
}

function StepRow({
  active,
  done,
  icon,
  title,
  detail,
}: {
  active: boolean;
  done: boolean;
  icon: React.ReactNode;
  title: string;
  detail: string;
}) {
  return (
    <li className="flex gap-token-3">
      <span
        className={
          done
            ? "text-tier-end-to-end"
            : active
              ? "text-brass-core"
              : "text-content-dim"
        }
      >
        {icon}
      </span>
      <span>
        <span className={done || active ? "text-content-bright" : "text-content-mute"}>{title}</span>
        <span className="block text-xs text-content-dim">{detail}</span>
      </span>
    </li>
  );
}
