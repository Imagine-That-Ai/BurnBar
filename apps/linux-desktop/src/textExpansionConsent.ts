const KEY = 'openburnbar.linux.textExpansion.consent.v1';

export type TextExpansionConsent = {
  inAppOnly: boolean;
  acknowledgedAt: string;
  declinedGlobalCapture: boolean;
};

export function readTextExpansionConsent(): TextExpansionConsent | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    return JSON.parse(raw) as TextExpansionConsent;
  } catch {
    return null;
  }
}

export function writeTextExpansionConsent(consent: Omit<TextExpansionConsent, 'acknowledgedAt'>): TextExpansionConsent {
  const next: TextExpansionConsent = { ...consent, acknowledgedAt: new Date().toISOString() };
  localStorage.setItem(KEY, JSON.stringify(next));
  return next;
}