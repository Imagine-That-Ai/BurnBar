/**
 * Extension logger with lightweight PII and secret redaction.
 *
 * Keep extension diagnostics useful without writing bearer tokens, API keys,
 * DSNs, or private key material to the VS Code / Cursor host logs.
 */

const SENSITIVE_PATTERNS: RegExp[] = [
  /\b(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi,
  /\b(sk-[A-Za-z0-9]{16,})\b/g,
  /\b(xox[baprs]-[A-Za-z0-9-]+)\b/g,
  /\b([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})\b/g,
  /\b(private[_-]?key|api[_-]?key|token|secret|dsn)=([^\s&]+)/gi,
  /https:\/\/[a-f0-9]+@[a-z0-9.-]+\.ingest\.sentry\.io\/\d+/gi
];

function redact(value: unknown): string {
  const text = value instanceof Error ? `${value.name}: ${value.message}` : String(value);
  return SENSITIVE_PATTERNS.reduce(
    (current, pattern) => current.replace(pattern, (_match, prefix) => `${prefix ?? ''}[REDACTED]`),
    text
  );
}

function redactArgs(args: unknown[]): string[] {
  return args.map(redact);
}

export const logger = {
  debug: (...args: unknown[]): void => {
    console.debug(...redactArgs(args));
  },
  info: (...args: unknown[]): void => {
    console.info(...redactArgs(args));
  },
  warn: (...args: unknown[]): void => {
    console.warn(...redactArgs(args));
  },
  error: (...args: unknown[]): void => {
    console.error(...redactArgs(args));
  }
};
