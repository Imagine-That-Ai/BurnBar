/**
 * Extension logger with PII/secret redaction.
 *
 * Wraps console methods to scrub sensitive patterns before logging.
 * All extension code should import from this module instead of using console directly.
 */

/** Patterns that indicate sensitive data that should be redacted in logs. */
const REDACT_PATTERNS: ReadonlyArray<[RegExp, string | ((match: string) => string)]> = [
  // Sensitive URL query parameters, including callback URLs copied into errors.
  [
    /(^|[?&])((?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|token|key|secret|password|passwd|pwd|auth|authorization|credential|code|session|jwt|dsn)=)[^&#\s]+/gi,
    '$1$2[REDACTED]'
  ],
  // Authorization-like header values copied into text blobs.
  [/\b(authorization|proxy-authorization)\s*[:=]\s*(?:bearer|basic)?\s+[^\s,;]+/gi, '$1: [REDACTED]'],
  // Standalone bearer/basic credentials.
  [/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}/gi, '$1 [REDACTED]'],
  // API keys and tokens
  [
    /\b(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password|passwd|pwd|auth|authorization|credential|client[_-]?secret|private[_-]?key|session[_-]?token|dsn)\b(\s*[:=]\s*["']?)[^"'\s,;{}&#]+/gi,
    '$1$2[REDACTED]'
  ],
  // Common provider token prefixes. Keep this as shape-based redaction; tests use low-risk fixtures.
  [/\b(?:gh[pousr]_|github_pat_|xox[baprs]-|sk-[A-Za-z0-9]|AIza)[A-Za-z0-9_=-]{8,}/g, '[TOKEN_REDACTED]'],
  // Firebase tokens (long base64-like strings > 30 chars)
  [/eyJ[\w.-]{28,}/g, '[JWT_REDACTED]'],
  // Email addresses
  [/[\w.+-]+@[\w-]+\.[\w.]{2,}/g, '[EMAIL_REDACTED]'],
  // Local filesystem paths, which can leak usernames, project names, and source layout.
  [
    /(?:file:\/\/)?\/(?:Users|home|private\/var|var\/folders|private\/tmp|tmp)\/[^\s'"<>),;]+/g,
    '[LOCAL_PATH_REDACTED]'
  ],
  [/\b[A-Za-z]:\\Users\\[^"'<>),;\s]+/g, '[LOCAL_PATH_REDACTED]'],
  // IPv4 addresses that look like internal infrastructure
  [/\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '[INTERNAL_IP_REDACTED]'],
  // Long hex strings that look like secrets (32+ hex chars)
  [/\b[0-9a-f]{32,}\b/gi, (match: string) => (match.length > 40 ? '[HEX_REDACTED]' : match)]
];

/**
 * Scrubs PII and secrets from a string value.
 */
export function redactSensitiveText(value: string): string {
  let result = value;
  for (const [pattern, replacement] of REDACT_PATTERNS) {
    result =
      typeof replacement === 'string' ? result.replace(pattern, replacement) : result.replace(pattern, replacement);
  }
  return result;
}

/**
 * Safely serializes a value to a loggable string, scrubbing sensitive data.
 */
function serialize(value: unknown): string {
  if (typeof value === 'string') {
    return redactSensitiveText(value);
  }
  if (value instanceof Error) {
    return redactSensitiveText(value.message);
  }
  try {
    return redactSensitiveText(JSON.stringify(value) ?? String(value));
  } catch {
    return '[UNSERIALIZABLE]';
  }
}

/** Extension logger with automatic PII/secret redaction. */
export const logger = {
  info: (message: string, ...args: unknown[]): void => {
    console.log(`[OpenBurnBar] ${redactSensitiveText(message)}`, ...args.map(serialize));
  },
  warn: (message: string, ...args: unknown[]): void => {
    console.warn(`[OpenBurnBar] ${redactSensitiveText(message)}`, ...args.map(serialize));
  },
  error: (message: string, ...args: unknown[]): void => {
    console.error(`[OpenBurnBar] ${redactSensitiveText(message)}`, ...args.map(serialize));
  },
  debug: (message: string, ...args: unknown[]): void => {
    if (process.env.OPENBURNBAR_DEBUG === 'true') {
      console.log(`[OpenBurnBar:debug] ${redactSensitiveText(message)}`, ...args.map(serialize));
    }
  }
};
