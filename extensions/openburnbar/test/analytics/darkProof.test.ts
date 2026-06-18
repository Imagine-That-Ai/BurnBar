import { createRequire } from 'node:module';

import { afterEach, describe, expect, it } from 'vitest';

/**
 * THE load-bearing proof of pre-consent darkness, against the REAL transport
 * (not a fake). Mirrors the macOS guarantee "an un-consented session never
 * builds the client" and the website's "zero Amplitude bytes pre-consent".
 *
 * The transport's only path to the SDK is a dynamic `import('@amplitude/analytics-node')`
 * inside `start()`. So:
 *   1. Importing the transport module loads ZERO Amplitude code.
 *   2. Constructing the transport loads ZERO Amplitude code.
 *   3. `track()` before `start()` loads ZERO Amplitude code (events queue, no SDK).
 *   4. Only `start()` — which the recorder calls solely after the consent+key gate
 *      passes — pulls the SDK in.
 *
 * We detect "the SDK is loaded" two ways: the module appears in the CJS
 * `require.cache`, and a fresh `require.resolve`'d module id is present. The build
 * target is commonjs (tsconfig `module: commonjs`), so Amplitude resolves through
 * the CJS cache.
 */

const require = createRequire(import.meta.url);

function amplitudeResolvedId(): string {
  return require.resolve('@amplitude/analytics-node');
}

function isAmplitudeLoaded(): boolean {
  const id = amplitudeResolvedId();
  // Direct cache hit, or any cached module whose path is inside the package.
  if (require.cache[id]) return true;
  return Object.keys(require.cache).some((p) => p.includes(`${'@amplitude'}/analytics-node`));
}

describe('pre-consent darkness — real AmplitudeTransport never loads the SDK early', () => {
  afterEach(() => {
    // Drop any Amplitude modules a `start()` test loaded, so each case is clean.
    for (const p of Object.keys(require.cache)) {
      if (p.includes('@amplitude')) delete require.cache[p];
    }
  });

  it('the package is NOT loaded merely by importing the transport module', async () => {
    expect(isAmplitudeLoaded()).toBe(false);
    await import('../../src/analytics/amplitudeTransport');
    expect(isAmplitudeLoaded()).toBe(false);
  });

  it('constructing the transport and tracking BEFORE start loads no SDK', async () => {
    const { AmplitudeTransport } = await import('../../src/analytics/amplitudeTransport');
    const t = new AmplitudeTransport('device-uuid', 'US');
    // track() before start() must queue, not load the SDK.
    t.track('vscode.command.invoked', 'primary_action', { command_id: 'refresh' });
    expect(t.isStarted).toBe(false);
    expect(isAmplitudeLoaded()).toBe(false);
  });

  it('start() with an EMPTY key stays dark (no load, no started state)', async () => {
    const { AmplitudeTransport } = await import('../../src/analytics/amplitudeTransport');
    const t = new AmplitudeTransport('device-uuid', 'US');
    t.start('');
    expect(t.isStarted).toBe(false);
    expect(isAmplitudeLoaded()).toBe(false);
  });

  it('start() WITH a key is the only thing that loads the SDK', async () => {
    const { AmplitudeTransport } = await import('../../src/analytics/amplitudeTransport');
    const t = new AmplitudeTransport('device-uuid', 'US');
    expect(isAmplitudeLoaded()).toBe(false);

    t.start('a-real-looking-key-abcdef0123');
    // The dynamic import resolves on a microtask; await it.
    await new Promise((r) => setTimeout(r, 50));

    expect(t.isStarted).toBe(true);
    expect(isAmplitudeLoaded()).toBe(true);

    // Tear down: stop() drops the client; the recorder calls this on revoke.
    t.stop();
    expect(t.isStarted).toBe(false);
  });
});
