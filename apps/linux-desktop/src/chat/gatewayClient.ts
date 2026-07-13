export type GatewayChatRole = 'system' | 'user' | 'assistant' | 'tool';

export type GatewayChatMessage = {
  role: GatewayChatRole;
  content: string;
  attachments?: GatewayChatAttachmentReference[];
};

export type GatewayChatAttachmentReference = {
  attachmentId: string;
};

export type GatewayChatUsage = {
  promptTokens?: number;
  completionTokens?: number;
  totalTokens?: number;
};

export type GatewayToolCallDelta = {
  id: string;
  name: string;
  arguments: string;
  /** Daemon-issued run approval identity when the gateway provides one. */
  approvalID?: string;
};

export type GatewayChatStreamEvent =
  | { type: 'delta'; text: string }
  | { type: 'thinking'; text: string }
  | { type: 'tool_call'; toolCall: GatewayToolCallDelta }
  | { type: 'usage'; usage: GatewayChatUsage }
  | { type: 'done'; finishReason?: string };

export type NativeGatewayChatRequest = {
  requestId: string;
  model: string;
  messages: GatewayChatMessage[];
  signal?: AbortSignal;
};

export type NativeGatewayChatTransport = {
  start(
    request: Omit<NativeGatewayChatRequest, 'signal'>,
    onChunk: (chunk: string) => void
  ): Promise<void>;
  cancel(requestId: string): Promise<void>;
};

export type GatewayErrorKind = 'unreachable' | 'http' | 'unimplemented' | 'stream_interrupted' | 'invalid_response' | 'aborted';

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

type RawJson = unknown;

function object(value: RawJson): Record<string, RawJson> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, RawJson>) : null;
}

function str(value: RawJson): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function num(value: RawJson): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

export class OpenAICompatibleSSEParser {
  private buffer = '';
  private toolCallBuffers = new Map<string, GatewayToolCallDelta>();
  private toolCallIndexKeys = new Map<number, string>();

  push(chunk: string): GatewayChatStreamEvent[] {
    this.buffer += chunk.replace(/\r\n/g, '\n');
    const events: GatewayChatStreamEvent[] = [];
    while (true) {
      const index = this.buffer.indexOf('\n\n');
      if (index < 0) break;
      const raw = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 2);
      events.push(...this.parseEvent(raw));
    }
    return events;
  }

  finish(): GatewayChatStreamEvent[] {
    const rest = this.buffer.trim();
    this.buffer = '';
    return rest ? this.parseEvent(rest) : [];
  }

  private parseEvent(raw: string): GatewayChatStreamEvent[] {
    const data = raw
      .split('\n')
      .map((line) => line.trimEnd())
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trimStart())
      .join('\n')
      .trim();
    if (!data) return [];
    if (data === '[DONE]') return [{ type: 'done', finishReason: 'stop' }];
    let parsed: RawJson;
    try {
      parsed = JSON.parse(data);
    } catch {
      return [{ type: 'delta', text: data }];
    }
    const root = object(parsed);
    if (!root) return [];
    const usage = usageFrom(root.usage);
    const choices = Array.isArray(root.choices) ? root.choices : [];
    const events: GatewayChatStreamEvent[] = [];
    for (const choice of choices) {
      const choiceObject = object(choice);
      const delta = object(choiceObject?.delta) ?? object(choiceObject?.message);
      const content = str(delta?.content);
      if (content) events.push({ type: 'delta', text: content });
      const thinking = str(delta?.reasoning_content) ?? str(delta?.reasoning) ?? str(delta?.thinking);
      if (thinking) events.push({ type: 'thinking', text: thinking });
      const toolCalls = Array.isArray(delta?.tool_calls) ? delta.tool_calls : [];
      for (const rawCall of toolCalls) {
        const call = this.toolCallFrom(rawCall);
        if (call) events.push({ type: 'tool_call', toolCall: call });
      }
      const finishReason = str(choiceObject?.finish_reason);
      if (finishReason) events.push({ type: 'done', finishReason });
    }
    if (usage) events.push({ type: 'usage', usage });
    return events;
  }

  private toolCallFrom(raw: RawJson): GatewayToolCallDelta | null {
    const call = object(raw);
    const fn = object(call?.function);
    const index = num(call?.index);
    const explicitId = str(call?.id);
    const id = explicitId ?? (index === undefined ? undefined : this.toolCallIndexKeys.get(index) ?? `tool-${index}`);
    const name = str(fn?.name);
    const approvalID =
      str(call?.approvalID) ??
      str(call?.approvalId) ??
      str(call?.approval_id) ??
      str(fn?.approvalID) ??
      str(fn?.approvalId) ??
      str(fn?.approval_id);
    const args = fn?.arguments;
    const argumentsText = typeof args === 'string' ? args : args === undefined ? '' : JSON.stringify(args);
    if (!id && !name) return null;
    const key = id ?? `tool-${name}`;
    if (index !== undefined) this.toolCallIndexKeys.set(index, key);
    const previous = this.toolCallBuffers.get(key);
    const merged = {
      id: key,
      name: name ?? previous?.name ?? 'tool',
      arguments: `${previous?.arguments ?? ''}${argumentsText}`,
      approvalID: approvalID ?? previous?.approvalID
    };
    this.toolCallBuffers.set(key, merged);
    return merged;
  }
}

function usageFrom(raw: RawJson): GatewayChatUsage | null {
  const usage = object(raw);
  if (!usage) return null;
  return {
    promptTokens: num(usage.prompt_tokens) ?? num(usage.promptTokens),
    completionTokens: num(usage.completion_tokens) ?? num(usage.completionTokens),
    totalTokens: num(usage.total_tokens) ?? num(usage.totalTokens)
  };
}

function nativeGatewayError(error: unknown): GatewayChatError {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes('gateway_aborted')) {
    return new GatewayChatError('aborted', 'Chat stream aborted.');
  }
  const http = message.match(/gateway_http:(\d+):(.*)/s);
  if (http) {
    const status = Number(http[1]);
    const detail = http[2]?.trim() ?? '';
    const kind: GatewayErrorKind = status === 503 && /unimplemented|not available|stub/i.test(detail)
      ? 'unimplemented'
      : 'http';
    return new GatewayChatError(kind, detail ? `HTTP ${status}: ${detail}` : `HTTP ${status}`, { status, detail });
  }
  if (message.includes('gateway_stream_interrupted')) {
    return new GatewayChatError('stream_interrupted', 'Gateway stream was interrupted.');
  }
  if (message.includes('gateway_invalid_') || message.includes('gateway_response_too_large')) {
    return new GatewayChatError('invalid_response', message);
  }
  return new GatewayChatError('unreachable', message || 'Gateway unreachable.');
}

export async function* streamGatewayChatNative(
  transport: NativeGatewayChatTransport,
  request: NativeGatewayChatRequest
): AsyncGenerator<GatewayChatStreamEvent, void, void> {
  const selectedModel = request.model.trim();
  if (!selectedModel) {
    throw new GatewayChatError('invalid_response', 'Missing chat model.');
  }

  const parser = new OpenAICompatibleSSEParser();
  const queued: GatewayChatStreamEvent[] = [];
  let completed = false;
  let failure: GatewayChatError | null = null;
  let sawDone = false;
  let wake: (() => void) | null = null;
  const notify = () => {
    const pending = wake;
    wake = null;
    pending?.();
  };
  const append = (events: GatewayChatStreamEvent[]) => {
    for (const event of events) {
      if (event.type === 'done') sawDone = true;
      queued.push(event);
    }
    notify();
  };
  const abort = () => {
    if (completed) return;
    failure = new GatewayChatError('aborted', 'Chat stream aborted.');
    completed = true;
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
        (chunk) => {
          if (!completed) append(parser.push(chunk));
        }
      )
      .then(() => {
        if (completed) return;
        append(parser.finish());
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
      const event = queued.shift();
      if (event) {
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
