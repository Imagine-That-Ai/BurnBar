const SECRET_FIELD_PATTERN =
  /(["']?)(authorization|bearer|access_token|refresh_token|id_token|client_secret|api_key|app_check|private_key|passphrase)\1(\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:Bearer\s+)?[^\s,;]+)/gi;
const JWT_PATTERN =
  /(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{20,}\.?[A-Za-z0-9_.-]*/g;

export function sanitizeCertificationLog(text) {
  return String(text ?? "")
    .replace(SECRET_FIELD_PATTERN, "$1$2$1$3[REDACTED]")
    .replace(JWT_PATTERN, "[REDACTED_JWT]");
}
