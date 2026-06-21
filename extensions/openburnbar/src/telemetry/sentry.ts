/**
 * Sentry error tracking for the OpenBurnBar VS Code / Cursor extension.
 *
 * The extension runs in a Node.js host process, so we use @sentry/node.
 * Sentry is gracefully disabled when BURNBAR_EXTENSION_SENTRY_DSN is unset,
 * which keeps the dev/test experience noise-free.
 *
 * Usage:
 *   import { initSentry } from './telemetry/sentry';
 *
 *   initSentry(context.extension.packageJSON.version, isDev ? 'development' : 'production');
 */

import { logger, redactSensitiveText } from '../logger';

// ── Type-only import so the module is optional at runtime ─────────────────────

type SentryNodeModule = typeof import('@sentry/node');
type JsonObject = Record<string, unknown>;

let _sentry: SentryNodeModule | undefined;
let _initialized = false;

const SENSITIVE_FIELD_PATTERN =
  /authorization|proxy-authorization|cookie|set-cookie|password|passwd|pwd|secret|api[_-]?key|apikey|token|credential|client[_-]?secret|private[_-]?key|session|dsn/i;

function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Sanitizes arbitrary Sentry event payload data before egress. Keep this
 * conservative: diagnostics are useful, but extension telemetry must not carry
 * credentials, local paths, emails, prompt/code bodies, or copied request
 * secrets out of the user's machine.
 */
export function sanitizeTelemetryValue(value: unknown, keyHint = '', depth = 0): unknown {
  if (value === null || value === undefined) {
    return value;
  }

  if (SENSITIVE_FIELD_PATTERN.test(keyHint)) {
    return '[REDACTED]';
  }

  if (typeof value === 'string') {
    return redactSensitiveText(value);
  }

  if (typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }

  if (value instanceof Error) {
    const sanitized: JsonObject = {
      name: redactSensitiveText(value.name),
      message: redactSensitiveText(value.message)
    };
    if (value.stack) {
      sanitized.stack = redactSensitiveText(value.stack);
    }
    return sanitized;
  }

  if (depth >= 8) {
    return '[REDACTED_NESTED_OBJECT]';
  }

  if (Array.isArray(value)) {
    return value.map((item) => sanitizeTelemetryValue(item, keyHint, depth + 1));
  }

  if (!isJsonObject(value)) {
    return redactSensitiveText(String(value));
  }

  const sanitized: JsonObject = {};
  for (const [key, nestedValue] of Object.entries(value)) {
    sanitized[key] = sanitizeTelemetryValue(nestedValue, key, depth + 1);
  }
  return sanitized;
}

function sanitizeRecordInPlace(record: JsonObject, depth = 0): void {
  for (const [key, nestedValue] of Object.entries(record)) {
    if (SENSITIVE_FIELD_PATTERN.test(key)) {
      record[key] = '[REDACTED]';
      continue;
    }

    if (typeof nestedValue === 'string') {
      record[key] = redactSensitiveText(nestedValue);
      continue;
    }

    if (
      nestedValue === null ||
      nestedValue === undefined ||
      typeof nestedValue === 'number' ||
      typeof nestedValue === 'boolean'
    ) {
      continue;
    }

    if (nestedValue instanceof Error || Array.isArray(nestedValue) || !isJsonObject(nestedValue)) {
      record[key] = sanitizeTelemetryValue(nestedValue, key, depth + 1);
      continue;
    }

    if (depth >= 8) {
      record[key] = '[REDACTED_NESTED_OBJECT]';
      continue;
    }

    sanitizeRecordInPlace(nestedValue, depth + 1);
  }
}

function redactRequestFields(event: JsonObject): void {
  const request = event.request;
  if (!isJsonObject(request)) {
    return;
  }

  if (request.data !== undefined) {
    request.data = '[REDACTED]';
  }
  if (request.body !== undefined) {
    request.body = '[REDACTED]';
  }
  if (request.cookies !== undefined) {
    request.cookies = '[REDACTED]';
  }
  if (request.query_string !== undefined) {
    request.query_string =
      typeof request.query_string === 'string' ? redactSensitiveText(request.query_string) : '[REDACTED]';
  }
}

export function sanitizeSentryEvent<T extends object>(event: T): T {
  if (isJsonObject(event)) {
    sanitizeRecordInPlace(event);
    redactRequestFields(event);
  }

  return event;
}

function sanitizeSentryBreadcrumb<T extends object>(breadcrumb: T): T {
  if (isJsonObject(breadcrumb)) {
    sanitizeRecordInPlace(breadcrumb);
  }

  return breadcrumb;
}

/**
 * Lazily loads @sentry/node so the extension still activates even if the
 * package is not bundled (e.g., during local development without node_modules).
 */
async function getSentry(): Promise<SentryNodeModule | undefined> {
  if (_sentry !== undefined) return _sentry;
  try {
    _sentry = await import('@sentry/node');
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

    // Strip secrets, local paths, and PII from breadcrumbs before egress.
    beforeBreadcrumb(breadcrumb) {
      return sanitizeSentryBreadcrumb(breadcrumb);
    },

    // Drop expected noise so each issue represents a real bug.
    beforeSend(event) {
      const sanitized = sanitizeSentryEvent(event);
      const msg = typeof sanitized.message === 'string' ? sanitized.message : '';
      // Extension host restart is expected on VS Code reload — not actionable.
      if (msg.includes('Extension host terminated') || msg.includes('ECONNRESET')) {
        return null;
      }
      return sanitized;
    }
  });

  _initialized = true;
  logger.debug(`Sentry initialised (env=${environment}, release=openburnbar-extension@${extensionVersion})`);
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
