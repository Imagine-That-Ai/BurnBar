import type { GatewayProxyEvent } from '../tauriBridge.js';

export type GatewayChatRole = 'system' | 'user' | 'assistant' | 'tool';

export type GatewayChatMessage = {
  role: GatewayChatRole;
  content: string;
};

export type GatewayChatStreamEvent = GatewayProxyEvent;

export type NativeGatewayChatRequest = {
  requestId: string;
  model: string;
  messages: GatewayChatMessage[];
  signal?: AbortSignal;
};

export type NativeGatewayChatTransport = {
  start(
    request: Omit<NativeGatewayChatRequest, 'signal'>,
    onEvent: (event: GatewayChatStreamEvent) => void
  ): Promise<void>;
  cancel(requestId: string): Promise<void>;
};

export type GatewayErrorKind = 'unreachable' | 'http' | 'unimplemented' | 'stream_interrupted' | 'invalid_response' | 'aborted';

const MAX_QUEUED_EVENTS = 1_024;
const MAX_QUEUED_EVENT_COST = 24 * 1_024 * 1_024 + 64 * 1_024;
const MAX_COALESCED_TEXT_LENGTH = 64 * 1_024;

export class GatewayChatError extends Error {
  readonly kind: GatewayErrorKind;
  readonly status?: number;
  readonly detail?: string;

  constructor(kind: GatewayErrorKind, message: string, options: { status?: number; detail?: string } = {}) {
    super(message);
    this.name = 'GatewayChatError';
    this.kind = kind;
    this.status = options.status;
    this.detail = options.detail;
  }
}

function nativeGatewayError(error: unknown): GatewayChatError {
  const native = error && typeof error === 'object' ? error as Record<string, unknown> : null;
  const kind = typeof native?.kind === 'string' ? native.kind : '';
  if (kind === 'aborted') {
    return new GatewayChatError('aborted', 'Chat stream aborted.');
  }
  if (kind === 'http' && typeof native?.status === 'number') {
    const status = native.status;
    return new GatewayChatError('http', `HTTP ${status}`, { status });
  }
  if (kind === 'unimplemented') {
    return new GatewayChatError('unimplemented', 'Gateway chat is not implemented by this native runtime.');
  }
  if (kind === 'stream_interrupted') {
    return new GatewayChatError('stream_interrupted', 'Gateway stream was interrupted.');
  }
  if (kind === 'invalid_response') {
    const reason = typeof native?.reason === 'string' ? native.reason : 'invalid_response';
    return new GatewayChatError('invalid_response', `Gateway rejected an invalid response (${reason}).`);
  }
  if (kind === 'renderer_disconnected') {
    return new GatewayChatError('stream_interrupted', 'Gateway stream was interrupted.');
  }
  if (kind === 'token_unavailable') {
    return new GatewayChatError('unreachable', 'Gateway credential is unavailable.');
  }
  if (kind === 'unreachable') {
    return new GatewayChatError('unreachable', 'Gateway is unreachable.');
  }
  const message = error instanceof Error ? error.message : String(error);
  return new GatewayChatError('unreachable', message || 'Gateway unreachable.');
}

function eventCost(event: GatewayChatStreamEvent): number {
  switch (event.type) {
    case 'delta':
    case 'thinking':
      return 32 + event.text.length * 3;
    case 'tool_call':
      return 64 + (
        event.toolCall.key.length
        + event.toolCall.id.length
        + event.toolCall.name.length
        + event.toolCall.arguments.length
      ) * 3;
    case 'usage':
      return 64;
    case 'done':
      return 32 + (event.finishReason?.length ?? 0) * 3;
  }
}

export async function* streamGatewayChatNative(
  transport: NativeGatewayChatTransport,
  request: NativeGatewayChatRequest
): AsyncGenerator<GatewayChatStreamEvent, void, void> {
  const selectedModel = request.model.trim();
  if (!selectedModel) {
    throw new GatewayChatError('invalid_response', 'Missing chat model.');
  }

  let queued: Array<GatewayChatStreamEvent | undefined> = [];
  let queueHead = 0;
  let queuedCost = 0;
  let completed = false;
  let failure: GatewayChatError | null = null;
  let sawDone = false;
  let wake: (() => void) | null = null;
  const notify = () => {
    const pending = wake;
    wake = null;
    pending?.();
  };
  const clearQueue = () => {
    queued = [];
    queueHead = 0;
    queuedCost = 0;
  };
  const stopWithFailure = (error: GatewayChatError, cancelNative: boolean) => {
    if (completed) return;
    failure = error;
    completed = true;
    clearQueue();
    if (cancelNative) void transport.cancel(request.requestId);
    notify();
  };
  const append = (event: GatewayChatStreamEvent) => {
    if (completed) return;
    const tail = queued.length > queueHead ? queued[queued.length - 1] : undefined;
    if (tail?.type === 'delta' && event.type === 'delta'
        && tail.text.length + event.text.length <= MAX_COALESCED_TEXT_LENGTH) {
      tail.text += event.text;
      queuedCost += eventCost(event) - 32;
    } else if (tail?.type === 'thinking' && event.type === 'thinking'
        && tail.text.length + event.text.length <= MAX_COALESCED_TEXT_LENGTH) {
      tail.text += event.text;
      queuedCost += eventCost(event) - 32;
    } else if (tail?.type === 'usage' && event.type === 'usage') {
      queued[queued.length - 1] = event;
    } else {
      queued.push(event);
      queuedCost += eventCost(event);
    }
    if (event.type === 'done') sawDone = true;
    if (queued.length - queueHead > MAX_QUEUED_EVENTS || queuedCost > MAX_QUEUED_EVENT_COST) {
      stopWithFailure(
        new GatewayChatError('invalid_response', 'Gateway stream exceeded renderer backpressure limits.', {
          detail: 'renderer_backpressure'
        }),
        true
      );
      return;
    }
    notify();
  };
  const abort = () => {
    // A late AbortSignal must not discard events already queued after native
    // completion; the iterator still needs to drain them before returning.
    if (completed) return;
    failure = new GatewayChatError('aborted', 'Chat stream aborted.');
    completed = true;
    clearQueue();
    void transport.cancel(request.requestId);
    notify();
  };
  request.signal?.addEventListener('abort', abort, { once: true });
  if (request.signal?.aborted) abort();

  if (!completed) {
    void transport
      .start(
        {
          requestId: request.requestId,
          model: selectedModel,
          messages: request.messages
        },
        (event) => {
          append(event);
        }
      )
      .then(() => {
        if (completed) return;
        if (!sawDone) {
          failure = new GatewayChatError('stream_interrupted', 'Gateway stream ended before the completion marker.');
        }
        completed = true;
        notify();
      })
      .catch((error) => {
        if (completed) return;
        failure = nativeGatewayError(error);
        completed = true;
        notify();
      });
  }

  try {
    while (true) {
      const event = queued[queueHead];
      if (event) {
        queued[queueHead] = undefined;
        queueHead += 1;
        queuedCost = Math.max(0, queuedCost - eventCost(event));
        if (queueHead >= 256 && queueHead * 2 >= queued.length) {
          queued = queued.slice(queueHead);
          queueHead = 0;
        }
        yield event;
        continue;
      }
      if (completed) {
        if (failure) throw failure;
        return;
      }
      await new Promise<void>((resolve) => {
        wake = resolve;
      });
    }
  } finally {
    request.signal?.removeEventListener('abort', abort);
    if (!completed) void transport.cancel(request.requestId);
  }
}
