import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  GatewayChatError,
  OpenAICompatibleSSEParser,
  streamGatewayChatNative,
  type NativeGatewayChatTransport
} from './gatewayClient.js';

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

  it('preserves a daemon-issued approval identity without inventing one', () => {
    const parser = new OpenAICompatibleSSEParser();
    const events = parser.push(
      'data: {"choices":[{"delta":{"tool_calls":[{"id":"t-approved","approval_id":"run-approval-1","function":{"name":"workspace.write","arguments":"{}"}}]}}]}\n\n'
    );
    expect(events).toContainEqual({
      type: 'tool_call',
      toolCall: {
        id: 't-approved',
        name: 'workspace.write',
        arguments: '{}',
        approvalID: 'run-approval-1'
      }
    });
  });

  it('decodes bounded provider citation identities for live source navigation', () => {
    const parser = new OpenAICompatibleSSEParser();
    const events = parser.push(
      'data: {"choices":[{"delta":{"memory_citations":[{"id":"citation-1","label":"Earlier answer","message_id":"message-1","thread_id":"thread-1","state":"live"}]}}]}\n\n'
    );
    expect(events).toContainEqual({
      type: 'citations',
      citations: [{ id: 'citation-1', label: 'Earlier answer', messageId: 'message-1', threadID: 'thread-1', state: 'live' }]
    });
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

describe('streamGatewayChatNative', () => {
  it('streams through the native transport without a URL or bearer in renderer data', async () => {
    const start: NativeGatewayChatTransport['start'] = vi.fn(async (request, onChunk) => {
      expect(request).not.toHaveProperty('baseURL');
      expect(request).not.toHaveProperty('bearerToken');
      onChunk('data: {"choices":[{"delta":{"content":"native"}}]}\n\n');
      onChunk('data: [DONE]\n\n');
    });
    const events = [];
    for await (const event of streamGatewayChatNative(
      { start, cancel: vi.fn(async () => undefined) },
      {
        requestId: 'gateway-test-1',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    )) {
      events.push(event);
    }
    expect(events).toEqual([
      { type: 'delta', text: 'native' },
      { type: 'done', finishReason: 'stop' }
    ]);
  });

  it('forwards only opaque daemon attachment references', async () => {
    const start: NativeGatewayChatTransport['start'] = vi.fn(async (request, onChunk) => {
      expect(request.messages[0]).toEqual({
        role: 'user',
        content: 'summarize',
        attachments: [{ attachmentId: 'attachment-1' }]
      });
      expect(JSON.stringify(request)).not.toContain('contentBase64');
      onChunk('data: [DONE]\n\n');
    });
    for await (const _event of streamGatewayChatNative(
      { start, cancel: vi.fn(async () => undefined) },
      {
        requestId: 'gateway-attachment-ref',
        model: 'hermes',
        messages: [{
          role: 'user',
          content: 'summarize',
          attachments: [{ attachmentId: 'attachment-1' }]
        }]
      }
    )) {
      // The assertion is made by the native transport stub above.
    }
  });

  it('cancels the native request when the renderer aborts', async () => {
    const abort = new AbortController();
    const cancel = vi.fn(async () => undefined);
    const iterator = streamGatewayChatNative(
      {
        start: () => new Promise<void>(() => undefined),
        cancel
      },
      {
        requestId: 'gateway-test-abort',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }],
        signal: abort.signal
      }
    );
    const pending = iterator.next();
    abort.abort();
    await expect(pending).rejects.toMatchObject({ kind: 'aborted' });
    expect(cancel).toHaveBeenCalledWith('gateway-test-abort');
  });

  it('classifies a native 503 stub response as unimplemented', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async () => {
          throw new Error('gateway_http:503:chat completions unimplemented');
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-unimplemented',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({ kind: 'unimplemented', status: 503 });
  });

  it('treats native EOF before DONE as an interrupted stream', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async (_request, onChunk) => {
          onChunk('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n');
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-interrupted',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).resolves.toMatchObject({ value: { type: 'delta', text: 'partial' } });
    await expect(iterator.next()).rejects.toMatchObject({ kind: 'stream_interrupted' });
  });
});
