import {
  SAFARI_ASK_SYSTEM_PROMPT,
  SafariGatewayClient,
  buildSafariAskBody,
  parseGatewayJSONResponse,
  parseGatewaySSEPayload
} from '../src/background/gatewayClient';
import type { PageContext, SafariBootstrapResponse, ScreenshotResult } from '../src/shared/protocol';
import { requireRecordArray } from './helpers/assertions';

const pageContext: PageContext = {
  pageState: {
    tabId: 1,
    windowId: 10,
    url: 'https://example.com/product?token=redacted',
    title: 'Example product',
    navigationEpoch: 3,
    isActive: true,
    isTopFrame: true,
    capturedAt: '2026-08-10T12:00:00Z'
  },
  viewport: {
    width: 1024,
    height: 768,
    scrollX: 0,
    scrollY: 0,
    pageWidth: 1024,
    pageHeight: 1800,
    devicePixelRatio: 2,
    visualViewportOffsetLeft: 0,
    visualViewportOffsetTop: 0,
    visualViewportScale: 1
  },
  markdown: '# Mercury keyboard\n\nBuilt from aluminum.',
  snapshot: '[ref=obb-1] [role=button] [name="Buy"] [box=40,80,120,44]',
  nodes: [],
  truncated: false,
  sensitive: false,
  capturedAt: '2026-08-10T12:00:00Z'
};

const screenshot: ScreenshotResult = {
  dataUrl: 'data:image/jpeg;base64,anBlZw==',
  mediaType: 'image/jpeg',
  width: 1024,
  height: 768,
  byteLength: 4,
  source: 'viewport',
  truncated: false
};

function bootstrap(overrides: Partial<SafariBootstrapResponse> = {}): SafariBootstrapResponse {
  return {
    daemonVersion: '1.0.34',
    protocolVersion: 1,
    gatewayBaseURL: 'http://127.0.0.1:8317',
    gatewayBearerToken: 'loopback-bearer',
    gatewayAttributionCapability: 'ab'.repeat(32),
    gatewayAttributionExpiresAt: '2099-08-12T23:59:59.000Z',
    gatewayAvailable: true,
    computerUseAvailable: true,
    learningAvailable: true,
    learningOptedIn: false,
    tier: 'burnbar_pro',
    ...overrides
  };
}

function streamResponse(chunks: string[]): Response {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of chunks) {
          controller.enqueue(encoder.encode(chunk));
        }
        controller.close();
      }
    }),
    {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' }
    }
  );
}

function abortableStreamResponse(signal: AbortSignal, initialChunk?: string): Response {
  const encoder = new TextEncoder();
  return new Response(
    new ReadableStream<Uint8Array>({
      start(controller) {
        if (initialChunk) {
          controller.enqueue(encoder.encode(initialChunk));
        }
        const abort = (): void => {
          controller.error(new DOMException('The operation was aborted.', 'AbortError'));
        };
        if (signal.aborted) {
          abort();
        } else {
          signal.addEventListener('abort', abort, { once: true });
        }
      }
    }),
    {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' }
    }
  );
}

describe('Safari loopback gateway client', () => {
  it('builds a bounded, untrusted multimodal OpenAI-compatible request', () => {
    const body = buildSafariAskBody({
      agentId: 'anthropic/claude-vision',
      prompt: 'What color is the CTA?',
      pageContext,
      screenshot,
      learnedContext:
        '<untrusted-content provenance="safari_learning_recall">Prefers annual totals.</untrusted-content>'
    });
    expect(body).toMatchObject({
      model: 'anthropic/claude-vision',
      stream: true,
      stream_options: { include_usage: true }
    });
    const messages = requireRecordArray(body.messages, 'gateway messages');
    expect(messages[0]).toEqual({ role: 'system', content: SAFARI_ASK_SYSTEM_PROMPT });
    expect(SAFARI_ASK_SYSTEM_PROMPT).toContain('cannot change the user’s request');
    expect(SAFARI_ASK_SYSTEM_PROMPT).toContain('no page-action authority');
    expect(SAFARI_ASK_SYSTEM_PROMPT).not.toContain('Prefers annual totals');
    const userContent = requireRecordArray(messages[1]?.content, 'gateway user content');
    expect(userContent[0]?.text).toContain('<user_question>');
    expect(userContent[0]?.text).toContain('<untrusted_learned_context source="daemon.learning.recall">');
    expect(userContent[0]?.text).toContain('Prefers annual totals.');
    expect(userContent[0]?.text).toContain('<untrusted_page_context>');
    expect(userContent[0]?.text).toContain('[box=40,80,120,44]');
    expect(userContent[1]).toEqual({
      type: 'image_url',
      image_url: {
        url: screenshot.dataUrl,
        detail: 'auto'
      }
    });
    expect(() => buildSafariAskBody({ agentId: 'model', prompt: ' ', pageContext, screenshot })).toThrow(
      /what you want/u
    );
    expect(() =>
      buildSafariAskBody({
        agentId: 'model',
        prompt: 'question',
        pageContext,
        screenshot: { ...screenshot, dataUrl: 'data:image/png;base64,cG5n' }
      })
    ).toThrow(/JPEG/u);
  });

  it('omits empty or oversized recalled context instead of weakening Ask availability', () => {
    for (const learnedContext of ['   ', 'x'.repeat(16 * 1024 + 1)]) {
      const body = buildSafariAskBody({
        agentId: 'vision-model',
        prompt: 'Keep this question unchanged.',
        pageContext,
        screenshot,
        learnedContext
      });
      const messages = requireRecordArray(body.messages, 'gateway messages');
      const userContent = requireRecordArray(messages[1]?.content, 'gateway user content');
      expect(userContent[0]?.text).toContain('<user_question>\nKeep this question unchanged.\n</user_question>');
      expect(userContent[0]?.text).not.toContain('<untrusted_learned_context');
    }
  });

  it('parses only the supported streaming and non-streaming answer shapes', () => {
    expect(parseGatewaySSEPayload('{"choices":[{"delta":{"content":"Orange"}}]}')).toEqual({
      delta: 'Orange',
      done: false
    });
    expect(parseGatewaySSEPayload('[DONE]')).toEqual({ done: true });
    expect(parseGatewaySSEPayload('{"choices":[{"delta":{"role":"assistant"}}]}')).toEqual({
      done: false
    });
    expect(parseGatewaySSEPayload('{"choices":[{"delta":{},"finish_reason":"stop"}]}')).toEqual({
      done: false,
      finishReason: 'stop'
    });
    expect(parseGatewaySSEPayload('{"choices":[{"delta":{"content":"…"},"finish_reason":null}]}')).toEqual({
      delta: '…',
      done: false
    });
    expect(() => parseGatewaySSEPayload('not-json')).toThrow(/invalid gateway stream/u);
    expect(parseGatewayJSONResponse({ choices: [{ message: { content: 'The CTA is orange.' } }] })).toEqual({
      answer: 'The CTA is orange.'
    });
    expect(
      parseGatewayJSONResponse({ choices: [{ message: { content: 'Cut short' }, finish_reason: 'length' }] })
    ).toEqual({ answer: 'Cut short', finishReason: 'length' });
    expect(() =>
      parseGatewayJSONResponse({
        choices: [{ message: { content: 'x'.repeat(200_001) } }]
      })
    ).toThrow(/exceeded its limit/u);
    expect(() => parseGatewayJSONResponse({ choices: [] })).toThrow(/did not contain/u);
    expect(() => parseGatewayJSONResponse({ error: { message: 'No route available.' } })).toThrow(/No route/u);
  });

  it('streams through the exact loopback endpoint with fresh privacy-safe attribution', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      streamResponse([
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n',
        'data: {"choices":[{"delta":{"content":"The CTA "}}]}\n\n',
        'data: {"choices":[{"delta":{"content":"is orange."}}]}\n',
        'data: {"choices":[],"usage":{"prompt_tokens":10}}\n\n',
        'data: [DONE]\n\n'
      ])
    );
    const correlationIDs = ['2b0d4a57-a4e2-4c18-9af0-2026e06eaf51', '8e54d891-9aec-4a11-92f6-21a2336ae079'];
    let correlationIDIndex = 0;
    const correlationIDFactory = vi.fn(() => {
      const correlationID = correlationIDs[correlationIDIndex];
      if (!correlationID) {
        throw new Error('Unexpected Safari gateway correlation request.');
      }
      correlationIDIndex += 1;
      return correlationID;
    });
    const client = new SafariGatewayClient(fetcher, 120_000, correlationIDFactory);
    client.configure(bootstrap());
    const attributedPageContext: PageContext = {
      ...pageContext,
      pageState: {
        ...pageContext.pageState,
        tabId: 314_159_265,
        windowId: 271_828_182
      }
    };
    const deltas: string[] = [];
    for (const prompt of ['What color is the CTA?', 'Confirm the CTA color.']) {
      await expect(
        client.ask(
          {
            agentId: 'vision-model',
            prompt,
            pageContext: attributedPageContext,
            screenshot
          },
          (delta) => deltas.push(delta)
        )
      ).resolves.toEqual({ answer: 'The CTA is orange.' });
    }
    expect(deltas).toEqual(['The CTA ', 'is orange.', 'The CTA ', 'is orange.']);
    expect(correlationIDFactory).toHaveBeenCalledTimes(2);
    expect(fetcher).toHaveBeenCalledTimes(2);

    const observedCorrelationIDs: string[] = [];
    for (const [url, init] of fetcher.mock.calls) {
      expect(String(url)).toBe('http://127.0.0.1:8317/v1/chat/completions');
      expect(init).toMatchObject({
        method: 'POST',
        credentials: 'omit',
        cache: 'no-store',
        redirect: 'error'
      });
      const headers = new Headers(init?.headers);
      expect(headers.get('Authorization')).toBe('Bearer loopback-bearer');
      expect(headers.get('X-OpenBurnBar-Client')).toBe('openburnbar-safari-extension');
      expect(headers.get('X-OpenBurnBar-Attribution-Capability')).toBe('ab'.repeat(32));
      const correlationID = headers.get('X-OpenBurnBar-Correlation-ID');
      expect(correlationID).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu);
      observedCorrelationIDs.push(correlationID ?? '');

      const serializedBody = String(init?.body);
      expect(serializedBody).not.toContain('loopback-bearer');
      expect(serializedBody).not.toContain('openburnbar-safari-extension');
      expect(serializedBody).not.toContain(correlationID);

      const attributionOnly = `${headers.get('X-OpenBurnBar-Client')}\n${correlationID}`;
      for (const sensitiveValue of [
        'What color is the CTA?',
        'https://example.com/product?token=redacted',
        screenshot.dataUrl,
        'loopback-bearer',
        'vision-model',
        String(attributedPageContext.pageState.tabId),
        String(attributedPageContext.pageState.windowId),
        'command-secret',
        'safari-session-secret'
      ]) {
        expect(attributionOnly).not.toContain(sensitiveValue);
      }
    }
    expect(observedCorrelationIDs).toEqual(correlationIDs);
    expect(new Set(observedCorrelationIDs).size).toBe(2);
  });

  it('renews a near-expiry attribution capability before the single provider fetch', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      streamResponse(['data: {"choices":[{"delta":{"content":"Fresh answer"}}]}\n\n', 'data: [DONE]\n\n'])
    );
    const renewer = vi.fn(async () =>
      bootstrap({
        gatewayAttributionCapability: 'cd'.repeat(32),
        gatewayAttributionExpiresAt: new Date(Date.now() + 5 * 60_000).toISOString()
      })
    );
    const client = new SafariGatewayClient(fetcher);
    client.configure(
      bootstrap({
        gatewayAttributionExpiresAt: new Date(Date.now() + 1_000).toISOString()
      })
    );
    client.setConfigurationRenewer(renewer);

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).resolves.toEqual({ answer: 'Fresh answer' });

    expect(renewer).toHaveBeenCalledTimes(1);
    expect(fetcher).toHaveBeenCalledTimes(1);
    const headers = new Headers(fetcher.mock.calls[0]?.[1]?.headers);
    expect(headers.get('X-OpenBurnBar-Attribution-Capability')).toBe('cd'.repeat(32));
  });

  it('shares one native renewal across concurrent pre-contact checks', async () => {
    let resolveRenewal: ((value: SafariBootstrapResponse) => void) | undefined;
    const renewal = new Promise<SafariBootstrapResponse>((resolve) => {
      resolveRenewal = resolve;
    });
    const renewer = vi.fn(() => renewal);
    const client = new SafariGatewayClient();
    client.setConfigurationRenewer(renewer);

    const first = client.ensureProviderConfiguration();
    const second = client.ensureProviderConfiguration();
    expect(renewer).toHaveBeenCalledTimes(1);
    resolveRenewal?.(
      bootstrap({
        gatewayAttributionCapability: 'ef'.repeat(32),
        gatewayAttributionExpiresAt: new Date(Date.now() + 5 * 60_000).toISOString()
      })
    );

    await expect(Promise.all([first, second])).resolves.toEqual([undefined, undefined]);
    expect(renewer).toHaveBeenCalledTimes(1);
  });

  it('aborts an in-flight native renewal without contacting the provider', async () => {
    const fetcher = vi.fn(async () => streamResponse(['data: [DONE]\n\n']));
    let observedSignal: AbortSignal | undefined;
    const renewer = vi.fn(
      (signal: AbortSignal) =>
        new Promise<SafariBootstrapResponse>((_resolve, reject) => {
          observedSignal = signal;
          signal.addEventListener('abort', () => reject(new DOMException('The operation was aborted.', 'AbortError')), {
            once: true
          });
        })
    );
    const client = new SafariGatewayClient(fetcher);
    client.setConfigurationRenewer(renewer);

    const ensuring = client.ensureProviderConfiguration();
    expect(renewer).toHaveBeenCalledTimes(1);
    expect(client.abortActiveRequest()).toBe(true);

    await expect(ensuring).rejects.toMatchObject({ code: 'gateway_aborted', message: 'Stopped.' });
    expect(observedSignal?.aborted).toBe(true);
    expect(fetcher).not.toHaveBeenCalled();
    expect(client.isConfigured).toBe(false);
  });

  it('times out a non-cooperative native renewal without contacting the provider', async () => {
    const fetcher = vi.fn(async () => streamResponse(['data: [DONE]\n\n']));
    let observedSignal: AbortSignal | undefined;
    const renewer = vi.fn(
      (signal: AbortSignal) =>
        new Promise<SafariBootstrapResponse>(() => {
          observedSignal = signal;
        })
    );
    const client = new SafariGatewayClient(fetcher, 120_000, () => '2b0d4a57-a4e2-4c18-9af0-2026e06eaf51', 30_000, 5);
    client.setConfigurationRenewer(renewer);

    await expect(client.ensureProviderConfiguration()).rejects.toMatchObject({
      code: 'gateway_attribution_renewal_timeout',
      retryable: true
    });
    expect(observedSignal?.aborted).toBe(true);
    expect(fetcher).not.toHaveBeenCalled();
    expect(client.isConfigured).toBe(false);
    expect(client.abortActiveRequest()).toBe(false);
  });

  it.each([
    {
      name: 'missing',
      renewedBootstrap: (() => {
        const value = bootstrap();
        delete value.gatewayAttributionCapability;
        return value;
      })()
    },
    {
      name: 'malformed',
      renewedBootstrap: bootstrap({ gatewayAttributionCapability: 'not-a-capability' })
    },
    {
      name: 'expired',
      renewedBootstrap: bootstrap({ gatewayAttributionExpiresAt: '2026-08-12T00:00:00.000Z' })
    },
    {
      name: 'near-expiry',
      renewedBootstrap: bootstrap({
        gatewayAttributionExpiresAt: new Date(Date.now() + 1_000).toISOString()
      })
    }
  ])('performs zero fetches when $name renewal data fails closed', async ({ renewedBootstrap }) => {
    const fetcher = vi.fn(async () => streamResponse(['data: [DONE]\n\n']));
    const client = new SafariGatewayClient(fetcher);
    client.setConfigurationRenewer(vi.fn(async () => renewedBootstrap));

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toBeInstanceOf(Error);
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('does not renew a healthy capability or retry an ambiguous provider response', async () => {
    const fetcher = vi.fn(async () => new Response('Route unavailable', { status: 503 }));
    const renewer = vi.fn(async () => bootstrap());
    const client = new SafariGatewayClient(fetcher);
    client.configure(bootstrap());
    client.setConfigurationRenewer(renewer);

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_http_error' });

    expect(renewer).not.toHaveBeenCalled();
    expect(fetcher).toHaveBeenCalledTimes(1);
  });

  it('fails closed before network access when request attribution is not an opaque UUID', async () => {
    const fetcher = vi.fn(async () => streamResponse(['data: [DONE]\n\n']));
    const client = new SafariGatewayClient(fetcher, 120_000, () => pageContext.pageState.url);
    client.configure(bootstrap());

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_attribution_invalid' });
    expect(fetcher).not.toHaveBeenCalled();
  });

  it('aborts an active stream as an intentional Stop and rejects concurrent asks', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (!init?.signal) {
        throw new Error('Expected the gateway request to carry an AbortSignal.');
      }
      return abortableStreamResponse(init.signal, 'data: {"choices":[{"delta":{"content":"Partial answer"}}]}\n\n');
    });
    const client = new SafariGatewayClient(fetcher);
    client.configure(bootstrap());
    const deltas: string[] = [];
    const activeAsk = client.ask(
      {
        agentId: 'vision-model',
        prompt: 'Question',
        pageContext,
        screenshot
      },
      (delta) => deltas.push(delta)
    );
    await vi.waitFor(() => {
      expect(deltas).toEqual(['Partial answer']);
    });

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'A concurrent question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_request_in_progress', retryable: false });

    const stopped = expect(activeAsk).rejects.toMatchObject({
      code: 'gateway_aborted',
      message: 'Stopped.',
      retryable: false
    });
    expect(client.abortActiveRequest()).toBe(true);
    expect(client.abortActiveRequest()).toBe(false);
    await stopped;
  });

  it('keeps timeout cancellation distinct from a user Stop', async () => {
    const client = new SafariGatewayClient(
      vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
        if (!init?.signal) {
          throw new Error('Expected the gateway request to carry an AbortSignal.');
        }
        return abortableStreamResponse(init.signal);
      }),
      5
    );
    client.configure(bootstrap());

    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_timeout', retryable: true });
    expect(client.abortActiveRequest()).toBe(false);
  });

  it('supports the strict non-stream fallback and fails closed on unsafe bootstrap data', async () => {
    const client = new SafariGatewayClient(
      vi.fn(
        async () =>
          new Response(JSON.stringify({ choices: [{ message: { content: 'Fallback answer' } }] }), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          })
      )
    );
    client.configure(bootstrap({ gatewayBaseURL: 'http://localhost:8317/' }));
    const deltas: string[] = [];
    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        (delta) => deltas.push(delta)
      )
    ).resolves.toEqual({ answer: 'Fallback answer' });
    expect(deltas).toEqual(['Fallback answer']);

    for (const unsafeURL of [
      'https://127.0.0.1:8317',
      'http://example.com:8317',
      'http://127.0.0.1',
      'http://127.0.0.1:8317/proxy',
      'http://user:password@127.0.0.1:8317'
    ]) {
      expect(() => client.configure(bootstrap({ gatewayBaseURL: unsafeURL }))).toThrow(/loopback|port/u);
    }
    expect(() => client.configure(bootstrap({ gatewayBearerToken: ' ' }))).toThrow(/bearer/u);
    expect(() => client.configure(bootstrap({ gatewayAttributionCapability: 'not-a-capability' }))).toThrow(
      /attribution proof/u
    );
    expect(() => client.configure(bootstrap({ gatewayAttributionExpiresAt: '2026-08-12T00:00:00.000Z' }))).toThrow(
      /attribution proof/u
    );
    const missingCapability = bootstrap();
    delete missingCapability.gatewayAttributionCapability;
    expect(() => client.configure(missingCapability)).toThrow(/connection details/u);
    client.configure(bootstrap({ gatewayAvailable: false }));
    await expect(
      client.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toThrow(/unavailable/u);
  });

  it('surfaces bounded HTTP and stream errors', async () => {
    const httpClient = new SafariGatewayClient(vi.fn(async () => new Response('Route unavailable', { status: 503 })));
    httpClient.configure(bootstrap());
    await expect(
      httpClient.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_http_error', retryable: true });

    const emptyStreamClient = new SafariGatewayClient(
      vi.fn(async () => streamResponse(['data: {"choices":[]}\n\n', 'data: [DONE]\n\n']))
    );
    emptyStreamClient.configure(bootstrap());
    await expect(
      emptyStreamClient.ask(
        {
          agentId: 'vision-model',
          prompt: 'Question',
          pageContext,
          screenshot
        },
        () => undefined
      )
    ).rejects.toMatchObject({ code: 'gateway_response_invalid' });
  });

  describe('answer completeness', () => {
    const askRequest = {
      agentId: 'vision-model',
      prompt: 'Summarize this page.',
      pageContext,
      screenshot
    };

    it('delivers every delta of a long multi-frame stream and reports the provider finish reason', async () => {
      const words = Array.from({ length: 120 }, (_, index) => `word${index} `);
      const frames = words.map((word) => `data: ${JSON.stringify({ choices: [{ delta: { content: word } }] })}\n\n`);
      const client = new SafariGatewayClient(
        vi.fn(async () =>
          streamResponse([
            'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
            ...frames,
            'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
            'data: {"choices":[],"usage":{"completion_tokens":120}}\n\n',
            'data: [DONE]\n\n'
          ])
        )
      );
      client.configure(bootstrap());
      const deltas: string[] = [];
      await expect(client.ask(askRequest, (delta) => deltas.push(delta))).resolves.toEqual({
        answer: words.join(''),
        finishReason: 'stop'
      });
      expect(deltas).toEqual(words);
    });

    it('treats a provider finish_reason as completion even when the [DONE] sentinel is missing', async () => {
      const client = new SafariGatewayClient(
        vi.fn(async () =>
          streamResponse([
            'data: {"choices":[{"delta":{"content":"Complete "}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"answer."},"finish_reason":"stop"}]}\n\n'
          ])
        )
      );
      client.configure(bootstrap());
      await expect(client.ask(askRequest, () => undefined)).resolves.toEqual({
        answer: 'Complete answer.',
        finishReason: 'stop'
      });
    });

    it('surfaces a length-limited answer instead of presenting it as complete', async () => {
      const client = new SafariGatewayClient(
        vi.fn(async () =>
          streamResponse([
            'data: {"choices":[{"delta":{"content":"Here is the first"}}]}\n\n',
            'data: {"choices":[{"delta":{},"finish_reason":"length"}]}\n\n',
            'data: [DONE]\n\n'
          ])
        )
      );
      client.configure(bootstrap());
      await expect(client.ask(askRequest, () => undefined)).resolves.toEqual({
        answer: 'Here is the first',
        finishReason: 'length'
      });
    });

    it('fails loudly when the stream closes before the provider finished', async () => {
      const client = new SafariGatewayClient(
        vi.fn(async () => streamResponse(['data: {"choices":[{"delta":{"content":"Here"}}]}\n\n']))
      );
      client.configure(bootstrap());
      const deltas: string[] = [];
      await expect(client.ask(askRequest, (delta) => deltas.push(delta))).rejects.toMatchObject({
        code: 'gateway_stream_incomplete',
        retryable: true
      });
      expect(deltas).toEqual(['Here']);
    });

    it('reports a consumer failure honestly and releases the upstream request', async () => {
      let requestSignal: AbortSignal | undefined;
      const client = new SafariGatewayClient(
        vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
          requestSignal = init?.signal ?? undefined;
          return streamResponse([
            'data: {"choices":[{"delta":{"content":"Here"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":" is more"}}]}\n\n',
            'data: [DONE]\n\n'
          ]);
        })
      );
      client.configure(bootstrap());
      const consumerFailure = new ReferenceError("Can't find variable: window");
      await expect(
        client.ask(askRequest, () => {
          throw consumerFailure;
        })
      ).rejects.toMatchObject({
        code: 'ask_stream_consumer_failed',
        retryable: true,
        details: consumerFailure
      });
      expect(requestSignal?.aborted).toBe(true);
      expect(client.abortActiveRequest()).toBe(false);
    });

    it('keeps a slow but live stream alive past the stall window and only trips on silence', async () => {
      const encoder = new TextEncoder();
      const stallWindowMs = 40;
      const liveClient = new SafariGatewayClient(
        vi.fn(
          async () =>
            new Response(
              new ReadableStream<Uint8Array>({
                async start(controller) {
                  for (let index = 0; index < 8; index += 1) {
                    await new Promise((resolve) => setTimeout(resolve, stallWindowMs / 2));
                    controller.enqueue(
                      encoder.encode(`data: ${JSON.stringify({ choices: [{ delta: { content: `${index} ` } }] })}\n\n`)
                    );
                  }
                  controller.enqueue(encoder.encode('data: [DONE]\n\n'));
                  controller.close();
                }
              }),
              { status: 200, headers: { 'Content-Type': 'text/event-stream' } }
            )
        ),
        stallWindowMs
      );
      liveClient.configure(bootstrap());
      await expect(liveClient.ask(askRequest, () => undefined)).resolves.toEqual({
        answer: '0 1 2 3 4 5 6 7 '
      });

      const silentClient = new SafariGatewayClient(
        vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
          if (!init?.signal) {
            throw new Error('Expected the gateway request to carry an AbortSignal.');
          }
          return abortableStreamResponse(init.signal, 'data: {"choices":[{"delta":{"content":"Here"}}]}\n\n');
        }),
        stallWindowMs
      );
      silentClient.configure(bootstrap());
      const deltas: string[] = [];
      await expect(silentClient.ask(askRequest, (delta) => deltas.push(delta))).rejects.toMatchObject({
        code: 'gateway_timeout',
        message: 'OpenBurnBar’s gateway stopped sending the answer.',
        retryable: true
      });
      expect(deltas).toEqual(['Here']);
    });
  });
});
