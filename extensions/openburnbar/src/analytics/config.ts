/**
 * Amplitude key + server-zone resolution for the extension, mirroring the
 * key-injection seam used by `src/telemetry/sentry.ts` (the `__SENTRY_DSN__`
 * placeholder + env-var fallback) and the macOS `AnalyticsConfig.swift`
 * (`__AMPLITUDE_API_KEY__`).
 *
 * Amplitude client-side keys are write-only ingestion identifiers (like a Sentry
 * DSN) — but we still COMMIT ZERO KEYS. The repo ships the placeholder; CI bakes
 * the real per-environment key (separate dev/staging vs production Amplitude
 * projects) just before `tsc` runs:
 *
 *   BURNBAR_EXTENSION_AMPLITUDE_API_KEY=… \
 *     bash scripts/ci/inject-amplitude-extension-config.sh
 *
 * With no key the placeholder is left in place, `resolveAmplitudeApiKey()`
 * returns `''`, and the recorder's key+consent gate keeps analytics DARK by
 * construction — the SDK client is never even constructed. Local/dev builds are
 * safe without any secret.
 */

/** The literal CI replaces. Kept as a standalone constant so a future grep
 *  (`__AMPLITUDE_API_KEY__`) finds exactly one occurrence to inject. */
const INJECTED_API_KEY = '__AMPLITUDE_API_KEY__';

/** Env var a developer running from source can set to exercise the real path. */
const ENV_API_KEY = 'BURNBAR_EXTENSION_AMPLITUDE_API_KEY';
const ENV_SERVER_ZONE = 'BURNBAR_EXTENSION_AMPLITUDE_SERVER_ZONE';

/** The placeholder is unreplaced when it still equals its template form. We
 *  compare against the reconstructed token so the literal check itself can't be
 *  defeated by the sed replacement (CI never rewrites this expression). */
function isPlaceholderUnreplaced(value: string): boolean {
  return value === ['__AMPLITUDE', 'API', 'KEY__'].join('_');
}

/**
 * Resolve the API key. First the CI-injected literal (if replaced), then the env
 * var. Returns `''` when neither is present — which makes the recorder dark.
 */
export function resolveAmplitudeApiKey(env: Record<string, string | undefined> = process.env): string {
  if (!isPlaceholderUnreplaced(INJECTED_API_KEY) && INJECTED_API_KEY.length > 0) {
    return INJECTED_API_KEY;
  }
  const fromEnv = env[ENV_API_KEY];
  return typeof fromEnv === 'string' ? fromEnv.trim() : '';
}

export type AmplitudeServerZone = 'US' | 'EU';

/** Resolve the server zone (US default). EU only when explicitly configured. */
export function resolveServerZone(env: Record<string, string | undefined> = process.env): AmplitudeServerZone {
  return env[ENV_SERVER_ZONE] === 'EU' ? 'EU' : 'US';
}
