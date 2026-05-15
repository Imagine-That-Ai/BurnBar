export class HttpError extends Error {
  constructor(public readonly status: number, message: string, public readonly code = "http_error") {
    super(message);
  }
}

export class McpError extends Error {
  constructor(public readonly code: number, message: string, public readonly data?: unknown) {
    super(message);
  }
}

export function jsonRpcError(id: unknown, code: number, message: string, data?: unknown) {
  return {
    jsonrpc: "2.0",
    id: id ?? null,
    error: { code, message, ...(data === undefined ? {} : { data }) }
  };
}
