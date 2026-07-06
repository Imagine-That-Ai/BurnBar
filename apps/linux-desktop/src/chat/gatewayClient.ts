export type GatewayChatRole = 'system' | 'user' | 'assistant' | 'tool';

export type GatewayChatMessage = {
  role: GatewayChatRole;
  content: string;
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
};

export type GatewayChatStreamEvent =
  | { type: 'delta'; text: string }
  | { type: 'thinking'; text: string }
  | { type: 'tool_call'; toolCall: GatewayToolCallDelta }
  | { type: 'usage'; usage: GatewayChatUsage }
  | { type: 'done'; finishReason?: string };

export type GatewayChatRequest = {
  baseURL: string;
  model: string;
  messages: GatewayChatMessage[];
  bearerToken?: string;
  signal?: AbortSignal;
  timeoutMs?: number;
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

function errorMessageFromBody(body: string): string {
  const trimmed = body.trim();
  if (!trimmed) return '';
  try {
    const parsed = object(JSON.parse(trimmed));
    const error = parsed?.error;
    if (typeof error === 'string') return error;
    const errorObject = object(error);
    return (
      str(errorObject?.message) ??
      str(errorObject?.detail) ??
      str(errorObject?.code) ??
      str(parsed?.message) ??
      str(parsed?.detail) ??
      trimmed
    );
  } catch {
    return trimmed;
  }
}

function gatewayURL(baseURL: string, path: string): string {
  const url = new URL(baseURL);
  url.pathname = path;
  url.search = '';
  return url.toString();
}

function withTimeout(signal: AbortSignal | undefined, timeoutMs: number): { signal: AbortSignal; cleanup: () => void } {
  const controller = new AbortController();
  const relayAbort = () => controller.abort(signal?.reason);
  if (signal?.aborted) relayAbort();
  signal?.addEventListener('abort', relayAbort, { once: true });
  const timer = timeoutMs > 0 ? globalThis.setTimeout(() => controller.abort(new DOMException('Request timed out', 'TimeoutError')), timeoutMs) : 0;
  return {
    signal: controller.signal,
    cleanup: () => {
      signal?.removeEventListener('abort', relayAbort);
      if (timer) globalThis.clearTimeout(timer);
    }
  };
}

export async function probeGatewayHealth(baseURL: string, bearerToken?: string, timeoutMs = 3000): Promise<boolean> {
  const { signal, cleanup } = withTimeout(undefined, timeoutMs);
  try {
    const headers: Record<string, string> = {};
    if (bearerToken?.trim()) headers.Authorization = `Bearer ${bearerToken.trim()}`;
    const response = await fetch(gatewayURL(baseURL, '/health'), { method: 'GET', headers, signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    cleanup();
  }
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
    const args = fn?.arguments;
    const argumentsText = typeof args === 'string' ? args : args === undefined ? '' : JSON.stringify(args);
    if (!id && !name) return null;
    const key = id ?? `tool-${name}`;
    if (index !== undefined) this.toolCallIndexKeys.set(index, key);
    const previous = this.toolCallBuffers.get(key);
    const merged = {
      id: key,
      name: name ?? previous?.name ?? 'tool',
      arguments: `${previous?.arguments ?? ''}${argumentsText}`
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

export async function* streamGatewayChat(request: GatewayChatRequest): AsyncGenerator<GatewayChatStreamEvent, void, void> {
  const selectedModel = request.model.trim();
  if (!selectedModel) {
    throw new GatewayChatError('invalid_response', 'Missing chat model.');
  }
  const { signal, cleanup } = withTimeout(request.signal, request.timeoutMs ?? 120_000);
  try {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream'
    };
    if (request.bearerToken?.trim()) headers.Authorization = `Bearer ${request.bearerToken.trim()}`;
    const response = await fetch(gatewayURL(request.baseURL, '/v1/chat/completions'), {
      method: 'POST',
      headers,
      signal,
      body: JSON.stringify({
        model: selectedModel,
        stream: true,
        stream_options: { include_usage: true },
        messages: request.messages
      })
    });

    if (!response.ok) {
      const body = await response.text().catch(() => '');
      const message = errorMessageFromBody(body);
      const detail = message ? `HTTP ${response.status}: ${message}` : `HTTP ${response.status}`;
      const kind: GatewayErrorKind = response.status === 503 && /unimplemented|not available|stub/i.test(message)
        ? 'unimplemented'
        : 'http';
      throw new GatewayChatError(kind, detail, { status: response.status, detail: message });
    }
    if (!response.body) {
      throw new GatewayChatError('invalid_response', 'Gateway response did not include a stream body.');
    }

    const parser = new OpenAICompatibleSSEParser();
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        for (const event of parser.push(value)) {
          yield event;
          if (event.type === 'done') return;
        }
      }
      for (const event of parser.finish()) yield event;
    } catch (error) {
      if (signal.aborted) throw new GatewayChatError('aborted', 'Chat stream aborted.');
      throw new GatewayChatError('stream_interrupted', error instanceof Error ? error.message : 'Chat stream interrupted.');
    } finally {
      reader.releaseLock();
    }
  } catch (error) {
    if (error instanceof GatewayChatError) throw error;
    if (signal.aborted || (error instanceof DOMException && error.name === 'AbortError')) {
      throw new GatewayChatError('aborted', 'Chat stream aborted.');
    }
    throw new GatewayChatError('unreachable', error instanceof Error ? error.message : 'Gateway unreachable.');
  } finally {
    cleanup();
  }
}
