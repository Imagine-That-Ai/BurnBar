import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  GatewayChatError,
  OpenAICompatibleSSEParser,
  probeGatewayHealth,
  streamGatewayChat
} from './gatewayClient.js';

function streamFromChunks(chunks: string[], signal?: AbortSignal, closeAfterChunks = true): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    start(controller) {
      signal?.addEventListener(
        'abort',
        () => controller.error(new DOMException('aborted', 'AbortError')),
        { once: true }
      );
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      if (closeAfterChunks) controller.close();
    }
  });
}

async function collect(request: Parameters<typeof streamGatewayChat>[0]) {
  const events = [];
  for await (const event of streamGatewayChat(request)) events.push(event);
  return events;
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('OpenAICompatibleSSEParser', () => {
  it('reassembles SSE chunks across packet boundaries', () => {
    const parser = new OpenAICompatibleSSEParser();
    const events = [
      ...parser.push('data: {"choices":[{"delta":{"content":"hel'),
      ...parser.push('lo"}}]}\n\ndata: {"choices":[{"finish_reason":"stop"}]}\n\n')
    ];
    expect(events).toEqual([
      { type: 'delta', text: 'hello' },
      { type: 'done', finishReason: 'stop' }
    ]);
  });

  it('parses thinking, tool-call, and usage tail frames', () => {
    const parser = new OpenAICompatibleSSEParser();
    const events = parser.push(
      'data: {"choices":[{"delta":{"reasoning_content":"check","tool_calls":[{"id":"t1","function":{"name":"workspace.read","arguments":"{\\"path\\":\\"README.md\\"}"}}]}}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}\n\n'
    );
    expect(events).toEqual([
      { type: 'thinking', text: 'check' },
      { type: 'tool_call', toolCall: { id: 't1', name: 'workspace.read', arguments: '{"path":"README.md"}' } },
      { type: 'usage', usage: { promptTokens: 1, completionTokens: 2, totalTokens: 3 } }
    ]);
  });

  it('accumulates split tool-call argument frames', () => {
    const parser = new OpenAICompatibleSSEParser();
    const events = parser.push(
      `data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, id: 'call-1', function: { name: 'workspace.read', arguments: '{"pa' } }] } }] })}\n\n` +
        `data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: 'th":"README.md"}' } }] } }] })}\n\n`
    );

    expect(events).toContainEqual({
      type: 'tool_call',
      toolCall: { id: 'call-1', name: 'workspace.read', arguments: '{"path":"README.md"}' }
    });
  });
});

describe('streamGatewayChat', () => {
  it('streams the OpenAI-compatible happy path', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(streamFromChunks(['data: {"choices":[{"delta":{"content":"ok"}}]}\n\n', 'data: [DONE]\n\n'])))
    );
    const events = await collect({
      baseURL: 'http://127.0.0.1:8642',
      model: 'hermes',
      messages: [{ role: 'user', content: 'hello' }]
    });
    expect(events).toEqual([
      { type: 'delta', text: 'ok' },
      { type: 'done', finishReason: 'stop' }
    ]);
    expect(fetch).toHaveBeenCalledWith(
      'http://127.0.0.1:8642/v1/chat/completions',
      expect.objectContaining({
        method: 'POST',
        body: JSON.stringify({
          model: 'hermes',
          stream: true,
          stream_options: { include_usage: true },
          messages: [{ role: 'user', content: 'hello' }]
        })
      })
    );
  });

  it('classifies gateway-unreachable failures', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new TypeError('connect ECONNREFUSED');
      })
    );
    await expect(
      collect({ baseURL: 'http://127.0.0.1:8642', model: 'hermes', messages: [] })
    ).rejects.toMatchObject({ kind: 'unreachable' });
  });

  it('classifies the Linux gateway 503 stub as unimplemented', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response('{"error":{"message":"chat completions unimplemented"}}', { status: 503 }))
    );
    await expect(
      collect({ baseURL: 'http://127.0.0.1:8642', model: 'hermes', messages: [] })
    ).rejects.toMatchObject({ kind: 'unimplemented', status: 503 });
  });

  it('treats EOF before DONE as an interrupted stream', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => new Response(streamFromChunks(['data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'])))
    );
    await expect(
      collect({ baseURL: 'http://127.0.0.1:8642', model: 'hermes', messages: [] })
    ).rejects.toMatchObject({ kind: 'stream_interrupted' });
  });

  it('aborts an active stream', async () => {
    const abort = new AbortController();
    vi.stubGlobal(
      'fetch',
      vi.fn(async (_url, init) => {
        const signal = (init as RequestInit).signal ?? abort.signal;
        return new Response(streamFromChunks(['data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'], signal, false));
      })
    );
    const iterator = streamGatewayChat({
      baseURL: 'http://127.0.0.1:8642',
      model: 'hermes',
      messages: [],
      signal: abort.signal
    });
    await expect(iterator.next()).resolves.toMatchObject({ value: { type: 'delta', text: 'partial' } });
    abort.abort();
    await expect(iterator.next()).rejects.toBeInstanceOf(GatewayChatError);
  });

  it('uses /health as the reachability probe', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status: 200 })));
    await expect(probeGatewayHealth('http://127.0.0.1:8642')).resolves.toBe(true);
    expect(fetch).toHaveBeenCalledWith('http://127.0.0.1:8642/health', expect.objectContaining({ method: 'GET' }));
  });

  it('passes bearer tokens to health probes', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response('{}', { status: 200 })));
    await expect(probeGatewayHealth('http://127.0.0.1:8642', 'secret-token')).resolves.toBe(true);
    expect(fetch).toHaveBeenCalledWith(
      'http://127.0.0.1:8642/health',
      expect.objectContaining({ headers: { Authorization: 'Bearer secret-token' } })
    );
  });
});
