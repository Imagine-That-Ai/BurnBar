/**
 * Pluggable entitlement-state cache.
 *
 * The three Node consumers each keep their OWN cache POLICY (positive/negative TTLs,
 * expiry-capped windows, deny caching) — that policy is intentionally NOT unified in
 * this first seam. This class is the shared MECHANISM the policies can plug into: a
 * monotonic-clock-injectable, per-key TTL map. Consumers that adopt it pass their own
 * `now` and compute their own `cachedUntilMs`; the package owns neither.
 */
export interface EntitlementCacheOptions {
  /** Injectable clock (epoch millis). Defaults to `Date.now`. Use for deterministic tests. */
  now?: () => number;
}

interface CacheEntry<T> {
  value: T;
  expiresAtMs: number;
}

export class EntitlementCache<T> {
  private readonly store = new Map<string, CacheEntry<T>>();
  private readonly now: () => number;

  constructor(options: EntitlementCacheOptions = {}) {
    this.now = options.now ?? (() => Date.now());
  }

  /** Returns the cached value when present and not past `expiresAtMs`, else `undefined`. */
  get(key: string): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAtMs <= this.now()) {
      this.store.delete(key);
      return undefined;
    }
    return entry.value;
  }

  /** Caches `value` under `key` until the absolute `expiresAtMs` (caller-computed). */
  set(key: string, value: T, expiresAtMs: number): void {
    this.store.set(key, { value, expiresAtMs });
  }

  delete(key: string): void {
    this.store.delete(key);
  }

  clear(): void {
    this.store.clear();
  }
}
