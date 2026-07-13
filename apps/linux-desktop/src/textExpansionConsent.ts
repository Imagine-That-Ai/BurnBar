import type { TextExpansionConsent, TextExpansionSnapshot } from './tauriBridge.js';

export type { TextExpansionConsent } from './tauriBridge.js';

export type TextExpansionConsentBackend = {
  textExpansionList(): Promise<TextExpansionSnapshot>;
  textExpansionConsentUpdate?(consent: Omit<TextExpansionConsent, 'acknowledgedAt'>): Promise<TextExpansionConsent>;
};

let backend: TextExpansionConsentBackend | null = null;
let backendReady = false;
let allowMemoryFallback = true;
let memoryConsent: TextExpansionConsent | null = null;
let consentError: string | null = null;

export function configureTextExpansionConsentStorage(
  next: TextExpansionConsentBackend | null,
  allowFallback = true
): void {
  backend = next;
  backendReady = false;
  allowMemoryFallback = allowFallback;
  memoryConsent = null;
  consentError = next || allowFallback ? null : 'Native text expansion storage is unavailable.';
}

export function textExpansionConsentError(): string | null {
  return consentError;
}

export async function hydrateTextExpansionConsentStorage(
  next: TextExpansionConsentBackend | null = backend
): Promise<TextExpansionConsent | null> {
  if (next !== backend) configureTextExpansionConsentStorage(next, allowMemoryFallback);
  if (!backend) return allowMemoryFallback ? memoryConsent : null;
  try {
    const snapshot = await backend.textExpansionList();
    memoryConsent = snapshot.consent ?? null;
    backendReady = true;
    consentError = null;
    return memoryConsent;
  } catch (error) {
    backendReady = false;
    consentError = error instanceof Error ? error.message : 'Native text expansion storage unavailable.';
    return allowMemoryFallback ? memoryConsent : null;
  }
}

export function readTextExpansionConsent(): TextExpansionConsent | null {
  return memoryConsent;
}

/**
 * Update the in-memory gate immediately and forward it to the daemon. The
 * daemon is the only durable owner; fixture mode intentionally remains memory-only.
 */
export function writeTextExpansionConsent(
  consent: Omit<TextExpansionConsent, 'acknowledgedAt'>
): TextExpansionConsent {
  const next: TextExpansionConsent = { ...consent, acknowledgedAt: new Date().toISOString() };
  memoryConsent = next;
  if (backendReady && backend?.textExpansionConsentUpdate) {
    void backend.textExpansionConsentUpdate(consent)
      .then((stored) => {
        memoryConsent = stored;
        consentError = null;
      })
      .catch((error: unknown) => {
        consentError = error instanceof Error ? error.message : 'Native text expansion consent save failed.';
      });
  } else if (!backendReady && !allowMemoryFallback) {
    consentError = 'Native text expansion storage is unavailable.';
  }
  return next;
}

export async function writeTextExpansionConsentPersisted(
  consent: Omit<TextExpansionConsent, 'acknowledgedAt'>
): Promise<TextExpansionConsent> {
  if (!backendReady || !backend?.textExpansionConsentUpdate) {
    if (!allowMemoryFallback) throw new Error('Native text expansion storage is unavailable.');
    return writeTextExpansionConsent(consent);
  }
  try {
    const stored = await backend.textExpansionConsentUpdate(consent);
    memoryConsent = stored;
    consentError = null;
    return stored;
  } catch (error) {
    consentError = error instanceof Error ? error.message : 'Native text expansion consent save failed.';
    throw error;
  }
}
