export type PublicErrorCode =
  | "bad_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "payload_too_large"
  | "verification_failed"
  | "dependency_unavailable"
  | "internal";

export class PublicError extends Error {
  constructor(
    readonly status: number,
    readonly code: PublicErrorCode,
    readonly publicMessage: string,
    readonly retryable = false,
  ) {
    super(publicMessage);
    this.name = "PublicError";
  }
}

export function publicError(error: unknown): PublicError {
  if (error instanceof PublicError) return error;
  return new PublicError(500, "internal", "Internal service error");
}
