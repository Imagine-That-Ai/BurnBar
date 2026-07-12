import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  GatewayChatError,
  streamGatewayChatNative,
  type NativeGatewayChatTransport
} from './gatewayClient.js';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('streamGatewayChatNative', () => {
  it('streams through the native transport without a URL or bearer in renderer data', async () => {
    const start: NativeGatewayChatTransport['start'] = vi.fn(async (request, onEvent) => {
      expect(request).not.toHaveProperty('baseURL');
      expect(request).not.toHaveProperty('bearerToken');
      onEvent({ type: 'delta', text: 'native' });
      onEvent({ type: 'done', finishReason: 'stop' });
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

  it('preserves an ordinary native HTTP 503 as a transient HTTP error', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async () => {
          throw { kind: 'http', status: 503 };
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-http-503',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({ kind: 'http', status: 503, message: 'HTTP 503' });
  });

  it('classifies only the explicit native capability error as unimplemented', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async () => {
          throw { kind: 'unimplemented' };
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-unimplemented',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({
      kind: 'unimplemented',
      message: 'Gateway chat is not implemented by this native runtime.'
    });
  });

  it('preserves a non-503 native HTTP status without a response body', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async () => {
          throw { kind: 'http', status: 401 };
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-http',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({ kind: 'http', status: 401, message: 'HTTP 401' });
  });

  it('treats native EOF before DONE as an interrupted stream', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async (_request, onEvent) => {
          onEvent({ type: 'delta', text: 'partial' });
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

  it('classifies native secret reflection as an invalid response without exposing details', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async () => {
          throw { kind: 'invalid_response', reason: 'secret_reflection' };
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-reflection',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({
      kind: 'invalid_response',
      message: 'Gateway rejected an invalid response (secret_reflection).'
    });
  });

  it('coalesces a limit-scale burst without a shifting queue or per-delta yields', async () => {
    const iterator = streamGatewayChatNative(
      {
        start: async (_request, onEvent) => {
          for (let index = 0; index < 10_000; index += 1) {
            onEvent({ type: 'delta', text: 'x' });
          }
          onEvent({ type: 'done', finishReason: 'stop' });
        },
        cancel: vi.fn(async () => undefined)
      },
      {
        requestId: 'gateway-test-burst',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).resolves.toMatchObject({
      value: { type: 'delta', text: 'x'.repeat(10_000) },
      done: false
    });
    await expect(iterator.next()).resolves.toMatchObject({ value: { type: 'done' }, done: false });
    await expect(iterator.next()).resolves.toEqual({ value: undefined, done: true });
  });

  it('fails closed and cancels when non-coalescible events exceed renderer backpressure', async () => {
    const cancel = vi.fn(async () => undefined);
    const iterator = streamGatewayChatNative(
      {
        start: async (_request, onEvent) => {
          for (let index = 0; index < 1_100; index += 1) {
            onEvent({ type: 'usage', usage: { totalTokens: index } });
            onEvent({ type: 'done', finishReason: String(index) });
          }
        },
        cancel
      },
      {
        requestId: 'gateway-test-backpressure',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }]
      }
    );

    await expect(iterator.next()).rejects.toMatchObject({
      kind: 'invalid_response',
      detail: 'renderer_backpressure'
    });
    expect(cancel).toHaveBeenCalledWith('gateway-test-backpressure');
  });

  it('abort discards queued events and bypasses them on the next read', async () => {
    const abort = new AbortController();
    const cancel = vi.fn(async () => undefined);
    const iterator = streamGatewayChatNative(
      {
        start: async (_request, onEvent) => {
          onEvent({ type: 'delta', text: 'first' });
          onEvent({ type: 'usage', usage: { totalTokens: 1 } });
          onEvent({ type: 'delta', text: 'must-not-render' });
          onEvent({ type: 'done', finishReason: 'stop' });
        },
        cancel
      },
      {
        requestId: 'gateway-test-abort-queued',
        model: 'hermes',
        messages: [{ role: 'user', content: 'hello' }],
        signal: abort.signal
      }
    );

    await expect(iterator.next()).resolves.toMatchObject({ value: { type: 'delta', text: 'first' } });
    abort.abort();
    await expect(iterator.next()).rejects.toMatchObject({ kind: 'aborted' });
    expect(cancel).toHaveBeenCalledWith('gateway-test-abort-queued');
  });
});
