/**
 * Extension logger with PII/secret redaction.
 *
 * Wraps console methods to scrub sensitive patterns before logging.
 * All extension code should import from this module instead of using console directly.
 */

/** Patterns that indicate sensitive data that should be redacted in logs. */
const REDACT_PATTERNS: ReadonlyArray<[RegExp, string | ((match: string) => string)]> = [
  // Bearer tokens
  [/\bBearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer [REDACTED]'],
  // OpenAI/Stripe-style secret keys
  [/\bsk-[A-Za-z0-9]{16,}\b/g, '[SECRET_KEY_REDACTED]'],
  // Slack tokens
  [/\bxox[baprs]-[A-Za-z0-9-]+\b/g, '[SLACK_TOKEN_REDACTED]'],
  // Sentry DSNs
  [/https:\/\/[a-f0-9]+@[a-z0-9.-]+\.ingest\.sentry\.io\/\d+/gi, '[SENTRY_DSN_REDACTED]'],
  // API keys and tokens
  [/([Aa]pi[_-]?[Kk]ey|[Tt]oken|[Ss]ecret|[Pp]assword|[Aa]uth)["\s:=]+["']?[\w.-]{8,}["']?/g, '$1=[REDACTED]'],
  // Firebase tokens (long base64-like strings > 30 chars)
  [/eyJ[\w.-]{28,}/g, '[JWT_REDACTED]'],
  // Email addresses
  [/[\w.+-]+@[\w-]+\.[\w.]{2,}/g, '[EMAIL_REDACTED]'],
  // IPv4 addresses that look like internal infrastructure
  [/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '[INTERNAL_IP_REDACTED]'],
  // Long hex strings that look like secrets (32+ hex chars)
  [/\b[0-9a-f]{32,}\b/gi, (match: string) => (match.length > 40 ? '[HEX_REDACTED]' : match)]
];

/**
 * Scrubs PII and secrets from a string value.
 */
function scrub(value: string): string {
  let result = value;
  for (const [pattern, replacement] of REDACT_PATTERNS) {
    result = result.replace(pattern, replacement as Parameters<string['replace']>[1]);
  }
  return result;
}

/**
 * Safely serializes a value to a loggable string, scrubbing sensitive data.
 */
function serialize(value: unknown): string {
  if (typeof value === 'string') {
    return scrub(value);
  }
  if (value instanceof Error) {
    return scrub(`${value.name}: ${value.message}`);
  }
  try {
    return scrub(JSON.stringify(value) ?? String(value));
  } catch {
    return '[UNSERIALIZABLE]';
  }
}

function writeInfoLine(prefix: string, message: string, args: unknown[]): void {
  const suffix = args.length > 0 ? ` ${args.map(serialize).join(' ')}` : '';
  process.stdout.write(`${prefix} ${scrub(message)}${suffix}\n`);
}

/** Extension logger with automatic PII/secret redaction. */
export const logger = {
  info: (message: string, ...args: unknown[]): void => {
    writeInfoLine('[OpenBurnBar]', message, args);
  },
  warn: (message: string, ...args: unknown[]): void => {
    console.warn(`[OpenBurnBar] ${scrub(message)}`, ...args.map(serialize));
  },
  error: (message: string, ...args: unknown[]): void => {
    console.error(`[OpenBurnBar] ${scrub(message)}`, ...args.map(serialize));
  },
  debug: (message: string, ...args: unknown[]): void => {
    if (process.env.OPENBURNBAR_DEBUG === 'true') {
      writeInfoLine('[OpenBurnBar:debug]', message, args);
    }
  }
};
