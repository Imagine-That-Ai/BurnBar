/**
 * Tri-state analytics consent, ported from
 * AgentLens/Services/Analytics/AnalyticsConsentStore.swift and mirrored from
 * website/src/lib/analytics/consent.ts.
 *
 * `unset` and `declined` are treated identically — both keep the extension dark
 * (no Amplitude SDK constructed, no network). Only `granted` permits egress.
 * Revoking sets `declined`, never returns to `unset` (the prompt does not
 * reappear).
 *
 * Persistence is the host's `ExtensionContext.globalState` (the VS Code idiom
 * for cross-session extension state), injected as a tiny `ConsentStorage` seam
 * so tests can supply an in-memory fake — exactly like the Swift store injects a
 * `UserDefaults` and the website injects a `ConsentStorage`.
 */
export type ConsentState = 'unset' | 'granted' | 'declined';

/** The slice of `Memento`/storage we depend on — lets tests inject a fake. */
export interface ConsentStorage {
  get(key: string): string | undefined;
  update(key: string, value: string): Thenable<void> | Promise<void> | void;
}

export const CONSENT_STORAGE_KEY = 'openburnbar.analytics.consentState';

export class ConsentStore {
  constructor(
    private readonly storage: ConsentStorage,
    private readonly key: string = CONSENT_STORAGE_KEY
  ) {}

  get state(): ConsentState {
    const raw = this.storage.get(this.key);
    return raw === 'granted' || raw === 'declined' ? raw : 'unset';
  }

  /** The single gate every send is checked against. */
  get isGranted(): boolean {
    return this.state === 'granted';
  }

  /** True once the user has answered the prompt either way (drives first-run UI). */
  get hasDecided(): boolean {
    return this.state !== 'unset';
  }

  grant(): void {
    void this.storage.update(this.key, 'granted');
  }

  decline(): void {
    void this.storage.update(this.key, 'declined');
  }

  /** Revoke = decline. Stops all future sends; the prompt does not reappear. */
  revoke(): void {
    void this.storage.update(this.key, 'declined');
  }
}
