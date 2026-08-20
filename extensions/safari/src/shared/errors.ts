export interface SerializedError {
  code: string;
  message: string;
  retryable: boolean;
  details?: unknown;
}

export class SafariExtensionError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly details?: unknown;

  constructor(code: string, message: string, options: { retryable?: boolean; details?: unknown } = {}) {
    super(message);
    this.name = 'SafariExtensionError';
    this.code = code;
    this.retryable = options.retryable ?? false;
    if (options.details !== undefined) {
      this.details = options.details;
    }
  }
}

export function serializeError(error: unknown, fallbackCode = 'unknown_error'): SerializedError {
  if (error instanceof SafariExtensionError) {
    return {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
      ...(error.details === undefined ? {} : { details: error.details })
    };
  }

  if (error instanceof DOMException) {
    return {
      code: error.name || fallbackCode,
      message: error.message || 'The browser rejected the operation.',
      retryable: error.name === 'AbortError' || error.name === 'TimeoutError'
    };
  }

  if (error instanceof Error) {
    return {
      code: fallbackCode,
      message: error.message,
      retryable: false
    };
  }

  return {
    code: fallbackCode,
    message: typeof error === 'string' ? error : 'An unknown error occurred.',
    retryable: false,
    ...(error === undefined ? {} : { details: error })
  };
}

export function errorMessage(error: unknown, fallback: string): string {
  const serialized = serializeError(error);
  return serialized.message || fallback;
}
