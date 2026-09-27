/**
 * Tri-state analytics consent, ported from
 * AgentLens/Services/Analytics/AnalyticsConsentStore.swift.
 *
 * `unset` and `declined` are treated identically — both keep the site dark
 * (no Amplitude module loaded, no network). Only `granted` permits egress.
 * Revoking sets `declined`, never returns to `unset`.
 */
export type ConsentState = "unset" | "granted" | "declined";

/** The slice of the Web Storage API we depend on — lets tests inject a fake. */
export interface ConsentStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const CONSENT_STORAGE_KEY = "burnbar-analytics-consent";

/** Taxonomy `consent_version` for the current website consent copy. */
export const ANALYTICS_CONSENT_VERSION = "1";

export class ConsentStore {
  constructor(
    private readonly storage: ConsentStorage,
    private readonly key: string = CONSENT_STORAGE_KEY
  ) {}

  get state(): ConsentState {
    const raw = this.storage.getItem(this.key);
    return raw === "granted" || raw === "declined" ? raw : "unset";
  }

  /** The single gate every send is checked against. */
  get isGranted(): boolean {
    return this.state === "granted";
  }

  /** True once the visitor has answered the prompt either way. */
  get hasDecided(): boolean {
    return this.state !== "unset";
  }

  grant(): void {
    this.storage.setItem(this.key, "granted");
  }

  decline(): void {
    this.storage.setItem(this.key, "declined");
  }

  /** Revoking is `declined`, not `unset` — the prompt does not reappear. */
  revoke(): void {
    this.storage.setItem(this.key, "declined");
  }
}
