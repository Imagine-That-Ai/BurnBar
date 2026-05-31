/**
 * Sentry error tracking for the OpenBurnBar VS Code / Cursor extension.
 *
 * The extension runs in a Node.js host process, so we use @sentry/node.
 * Sentry is gracefully disabled when BURNBAR_EXTENSION_SENTRY_DSN is unset,
 * which keeps the dev/test experience noise-free.
 *
 * Usage:
 *   import { initSentry, captureExtensionError } from './telemetry/sentry';
 *
 *   // In extension activate():
 *   initSentry(context.extension.packageJSON.version, isDev ? 'development' : 'production');
 *
 *   // Anywhere an error should be tracked:
 *   captureExtensionError(err, { component: 'DaemonClient', event: 'connect_failed' });
 */

import { logger } from '../logger';

// ── Type-only import so the module is optional at runtime ─────────────────────

type SentryNodeModule = typeof import('@sentry/node');

let _sentry: SentryNodeModule | undefined;
let _initialized = false;

/**
 * Lazily loads @sentry/node so the extension still activates even if the
 * package is not bundled (e.g., during local development without node_modules).
 */
async function getSentry(): Promise<SentryNodeModule | undefined> {
  if (_sentry !== undefined) return _sentry;
  try {
    _sentry = (await import('@sentry/node')) as SentryNodeModule;
    return _sentry;
  } catch {
    return undefined;
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

/**
 * Initialises Sentry for the extension process.
 *
 * Called once from `activate()`. Safe to call multiple times — subsequent
 * calls are ignored.
 *
 * @param extensionVersion  Version string from package.json (e.g. "1.2.3").
 * @param environment       "production" | "development" | "test".
 */
export async function initSentry(extensionVersion: string, environment: string): Promise<void> {
  if (_initialized) return;

  // DSN sources (first non-empty wins):
  //  1. Injected at build time by CI (BURNBAR_EXTENSION_SENTRY_DSN env → sed replacement)
  //  2. Runtime env var (developers running from source with env set)
  // DSNs are public ingest endpoints — safe to embed in the compiled bundle.
  const dsn =
    // __SENTRY_DSN__ is replaced by scripts/ci/inject-sentry-config-extension.sh
    // before tsc runs in CI. Falls back to the env var for local dev.
    ('__SENTRY_DSN__'.startsWith('https://') ? '__SENTRY_DSN__' : undefined) ??
    process.env.BURNBAR_EXTENSION_SENTRY_DSN;

  if (!dsn) {
    logger.debug('Sentry disabled: no DSN configured');
    return;
  }

  const Sentry = await getSentry();
  if (!Sentry) {
    logger.debug('Sentry disabled: @sentry/node not available');
    return;
  }

  Sentry.init({
    dsn,
    release: `openburnbar-extension@${extensionVersion}`,
    environment,

    // Low sampling rate to avoid overloading the ingest endpoint.
    tracesSampleRate: environment === 'production' ? 0.05 : 1.0,

    // Keep breadcrumbs terse — the extension logger already redacts PII.
    maxBreadcrumbs: 20,

    // Strip auth tokens from URL breadcrumbs.
    beforeBreadcrumb(breadcrumb) {
      if (breadcrumb.data?.url && typeof breadcrumb.data.url === 'string') {
        breadcrumb.data.url = breadcrumb.data.url.replace(
          /([?&](?:token|key|secret|auth))=[^&]+/gi,
          '$1=[REDACTED]'
        );
      }
      return breadcrumb;
    },

    // Drop expected noise so each issue represents a real bug.
    beforeSend(event) {
      const msg = typeof event.message === 'string' ? event.message : '';
      // Extension host restart is expected on VS Code reload — not actionable.
      if (msg.includes('Extension host terminated') || msg.includes('ECONNRESET')) {
        return null;
      }
      return event;
    },
  });

  _initialized = true;
  logger.debug(`Sentry initialised (env=${environment}, release=openburnbar-extension@${extensionVersion})`);
}

/**
 * Reports an error to Sentry with structured context.
 *
 * Safe to call before `initSentry` or when Sentry is disabled — silently
 * falls back to logging.
 *
 * @param err      The error to capture. Non-Error values are wrapped.
 * @param context  Structured key/value pairs added as Sentry extras.
 */
export function captureExtensionError(
  err: unknown,
  context?: Record<string, unknown>
): void {
  const error = err instanceof Error ? err : new Error(String(err));

  if (!_initialized || !_sentry) {
    logger.error(`[Sentry fallback] ${error.message}`, error);
    return;
  }

  const sentry = _sentry;
  sentry.withScope((scope) => {
    if (context) {
      for (const [key, value] of Object.entries(context)) {
        scope.setExtra(key, value);
      }
    }
    sentry.captureException(error);
  });
}

/**
 * Sets the active user identity on Sentry so errors can be grouped by user.
 * Only the first 8 characters of the UID are sent to avoid full PII exposure.
 *
 * @param uidHash  Truncated/hashed user identifier.
 */
export function setSentryUser(uidHash: string | undefined): void {
  if (!_initialized || !_sentry || !uidHash) return;
  _sentry.setUser({ id: uidHash.slice(0, 8) });
}

/**
 * Flush pending events and shut down Sentry.
 * Called from `deactivate()` to ensure in-flight events are sent before
 * the extension host terminates.
 */
export async function flushSentry(): Promise<void> {
  if (!_initialized || !_sentry) return;
  try {
    await _sentry.flush(2000);
  } catch {
    // Ignore flush errors during deactivation.
  }
}
