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
let consentGeneration = 0;
let consentMutationQueue: Promise<void> = Promise.resolve();

type ConsentContext = {
  backend: TextExpansionConsentBackend;
  generation: number;
};

function isCurrentContext(context: ConsentContext): boolean {
  return backend === context.backend && consentGeneration === context.generation;
}

function enqueueConsentMutation<T>(operation: () => Promise<T>): Promise<T> {
  const next = consentMutationQueue.then(operation);
  consentMutationQueue = next.then(() => undefined, () => undefined);
  return next;
}

function buildConsent(consent: Omit<TextExpansionConsent, 'acknowledgedAt'>): TextExpansionConsent {
  return { ...consent, acknowledgedAt: new Date().toISOString() };
}

export function configureTextExpansionConsentStorage(
  next: TextExpansionConsentBackend | null,
  allowFallback = true,
  preserveMemory = false
): void {
  const backendChanged = backend !== next;
  consentGeneration += 1;
  backend = next;
  backendReady = false;
  consentMutationQueue = Promise.resolve();
  allowMemoryFallback = allowFallback;
  if (!preserveMemory || backendChanged) memoryConsent = null;
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
  const context: ConsentContext = { backend, generation: consentGeneration };
  try {
    const snapshot = await context.backend.textExpansionList();
    if (!isCurrentContext(context)) return memoryConsent;
    memoryConsent = snapshot.consent ?? null;
    backendReady = true;
    consentError = null;
    return memoryConsent;
  } catch (error) {
    if (!isCurrentContext(context)) return memoryConsent;
    backendReady = false;
    consentError = error instanceof Error ? error.message : 'Native text expansion storage unavailable.';
    return allowMemoryFallback ? memoryConsent : null;
  }
}

export function readTextExpansionConsent(): TextExpansionConsent | null {
  return memoryConsent;
}

function increasesConsentPrivilege(
  previous: TextExpansionConsent | null,
  next: Omit<TextExpansionConsent, 'acknowledgedAt'>
): boolean {
  return (next.inAppOnly && previous?.inAppOnly !== true)
    || (next.systemIMEEnabled === true && previous?.systemIMEEnabled !== true);
}

/**
 * Update the in-memory gate immediately and forward it to the daemon. The
 * daemon is the only durable owner; fixture mode intentionally remains memory-only.
 */
export function writeTextExpansionConsent(
  consent: Omit<TextExpansionConsent, 'acknowledgedAt'>
): TextExpansionConsent {
  const next = buildConsent(consent);
  const previous = memoryConsent;
  memoryConsent = next;
  if (backendReady && backend?.textExpansionConsentUpdate) {
    const context: ConsentContext = { backend, generation: consentGeneration };
    void enqueueConsentMutation(async () => {
      if (!isCurrentContext(context) || !backendReady) throw new Error('Native text expansion storage changed; retry consent.');
      const stored = await context.backend.textExpansionConsentUpdate!(consent);
      if (!isCurrentContext(context)) throw new Error('Native text expansion storage changed; retry consent.');
      memoryConsent = stored;
      consentError = null;
    }).catch((error: unknown) => {
      if (!isCurrentContext(context)) return;
      // Enabling must fail closed if the daemon cannot durably record consent;
      // revocation remains local so a stale engine cannot keep expanding.
      memoryConsent = increasesConsentPrivilege(previous, consent) ? previous : next;
      consentError = error instanceof Error ? error.message : 'Native text expansion consent save failed.';
    });
  } else if (!backendReady && !allowMemoryFallback) {
    consentError = 'Native text expansion storage is unavailable.';
  } else if (backendReady && !backend?.textExpansionConsentUpdate && !allowMemoryFallback) {
    consentError = 'Native text expansion consent persistence is unavailable.';
  }
  return next;
}

export async function writeTextExpansionConsentPersisted(
  consent: Omit<TextExpansionConsent, 'acknowledgedAt'>
): Promise<TextExpansionConsent> {
  const next = buildConsent(consent);
  const previous = memoryConsent;
  if (!backendReady || !backend?.textExpansionConsentUpdate) {
    if (!allowMemoryFallback) {
      memoryConsent = increasesConsentPrivilege(previous, consent) ? previous : next;
      consentError = 'Native text expansion storage is unavailable.';
      throw new Error(consentError);
    }
    memoryConsent = next;
    return next;
  }
  const context: ConsentContext = { backend, generation: consentGeneration };
  memoryConsent = next;
  return enqueueConsentMutation(async () => {
    if (!isCurrentContext(context) || !backendReady) throw new Error('Native text expansion storage changed; retry consent.');
    try {
      const stored = await context.backend.textExpansionConsentUpdate!(consent);
      if (!isCurrentContext(context)) throw new Error('Native text expansion storage changed; retry consent.');
      memoryConsent = stored;
      consentError = null;
      return stored;
    } catch (error) {
      if (isCurrentContext(context)) {
        memoryConsent = increasesConsentPrivilege(previous, consent) ? previous : next;
        consentError = error instanceof Error ? error.message : 'Native text expansion consent save failed.';
      }
      throw error;
    }
  });
}
