// @vitest-environment node
//
// The MV3 background runs as a service worker (manifest.json →
// background.service_worker). Every other suite runs under jsdom, which
// quietly provides `window`, `document`, and friends — so a DOM-only global
// in the streaming path passes CI and only fails inside Safari, where the
// first delta throws ReferenceError and the answer stops after a word or two.
// This suite drives the real controller and gateway client through the same
// Ask flow with no DOM at all, so that class of regression fails here first.

import type { PopupResponse } from '../src/shared/messages';
import { authorizeCloudScreenshots, createControllerHarness, expectSuccess } from './helpers/controllerHarness';

const encoder = new TextEncoder();

function sseFrame(delta: string, finishReason?: string): string {
  return `data: ${JSON.stringify({
    choices: [{ delta: { content: delta }, ...(finishReason === undefined ? {} : { finish_reason: finishReason }) }]
  })}\n\n`;
}

/**
 * Emits one SSE frame per macrotask so the controller's flush timer, the
 * popup snapshot broadcasts, and the stall watchdog all interleave the way
 * they do against the live loopback gateway.
 */
function pacedStreamResponse(frames: string[], gapMs = 2): Response {
  return new Response(
    new ReadableStream<Uint8Array>({
      async start(controller) {
        for (const frame of frames) {
          await new Promise((resolve) => setTimeout(resolve, gapMs));
          controller.enqueue(encoder.encode(frame));
        }
        controller.close();
      }
    }),
    { status: 200, headers: { 'Content-Type': 'text/event-stream' } }
  );
}

function assistantSnapshots(runtimeMessages: unknown[]): string[] {
  const texts: string[] = [];
  for (const message of runtimeMessages) {
    if (typeof message !== 'object' || message === null || Reflect.get(message, 'type') !== 'background.snapshot') {
      continue;
    }
    const snapshot = Reflect.get(message, 'snapshot') as PopupResponse['snapshot'];
    const assistant = snapshot?.transcript.filter((entry) => entry.role === 'assistant').at(-1);
    if (assistant && assistant.text) {
      texts.push(assistant.text);
    }
  }
  return texts;
}

describe('Safari background controller inside a service worker scope', () => {
  it('runs with no DOM globals, exactly like the MV3 background service worker', () => {
    expect(typeof window).toBe('undefined');
    expect(typeof document).toBe('undefined');
    expect(typeof setTimeout).toBe('function');
    expect(typeof fetch).toBe('function');
  });

  it('streams a long multi-frame Ask answer to completion and renders progress along the way', async () => {
    const words = Array.from(
      { length: 60 },
      (_, index) => `${['Here', 'are', 'the', 'ingredients', 'you', 'need'][index % 6]}${index % 6 === 5 ? '. ' : ' '}`
    );
    const expectedAnswer = words.join('');
    const harness = createControllerHarness();
    harness.setGatewayHandler(async () =>
      pacedStreamResponse([
        'data: {"choices":[{"delta":{"role":"assistant"}}]}\n\n',
        ...words.map((word) => sseFrame(word)),
        'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n',
        'data: {"choices":[],"usage":{"completion_tokens":60}}\n\n',
        'data: [DONE]\n\n'
      ])
    );
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);

    const response = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What ingredients do I need here?'
    });

    expectSuccess(response);
    expect(response.snapshot.lastError).toBeUndefined();
    expect(response.snapshot.busy).toBe(false);
    expect(response.snapshot.transcript.at(-1)).toMatchObject({
      role: 'assistant',
      text: expectedAnswer,
      streaming: false
    });
    expect(response.snapshot.transcript.at(-1)?.error).toBeUndefined();
    expect(response.snapshot.transcript.at(-1)?.note).toBeUndefined();

    // The popup saw the answer grow, not just appear at the end: at least one
    // broadcast carried a strict, non-empty prefix of the final answer.
    const observed = assistantSnapshots(harness.controls.runtimeMessages);
    expect(observed.at(-1)).toBe(expectedAnswer);
    expect(observed.some((text) => text.length < expectedAnswer.length && expectedAnswer.startsWith(text))).toBe(true);
    for (let index = 1; index < observed.length; index += 1) {
      expect(observed[index]?.startsWith(observed[index - 1] ?? '')).toBe(true);
    }
    expect(harness.gatewayCalls).toHaveLength(1);
  });

  it('keeps partial text visible and says why when the gateway stops mid-answer', async () => {
    const harness = createControllerHarness();
    harness.setGatewayHandler(async () =>
      pacedStreamResponse([sseFrame('Here'), sseFrame(' are the first few words')])
    );
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);

    const response = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What ingredients do I need here?'
    });

    expect(response.ok).toBe(false);
    expect(response.snapshot?.lastError).toMatchObject({ code: 'gateway_stream_incomplete', retryable: true });
    expect(response.snapshot?.busy).toBe(false);
    expect(response.snapshot?.transcript.at(-1)).toMatchObject({
      role: 'assistant',
      text: 'Here are the first few words',
      streaming: false,
      error: true,
      note: 'Answer interrupted: OpenBurnBar’s gateway stream ended before the answer was complete.'
    });
  });

  it('flags an answer the model cut at its output limit', async () => {
    const harness = createControllerHarness();
    harness.setGatewayHandler(async () =>
      pacedStreamResponse([sseFrame('Here is the beginning'), sseFrame('', 'length'), 'data: [DONE]\n\n'])
    );
    await harness.controller.initialize();
    expectSuccess(await harness.controller.handlePopupRequest({ type: 'popup.requestSitePermission' }));
    await authorizeCloudScreenshots(harness);

    const response = await harness.controller.handlePopupRequest({
      type: 'popup.ask',
      prompt: 'What ingredients do I need here?'
    });

    expectSuccess(response);
    expect(response.snapshot.transcript.at(-1)).toMatchObject({
      role: 'assistant',
      text: 'Here is the beginning',
      streaming: false,
      note: 'The model reached its output limit, so this answer may be cut short.'
    });
    expect(response.snapshot.transcript.at(-1)?.error).toBeUndefined();
    expect(response.snapshot.activity.at(-1)).toMatchObject({
      tone: 'warning',
      text: 'The model reached its output limit, so this answer may be cut short.'
    });
  });
});
