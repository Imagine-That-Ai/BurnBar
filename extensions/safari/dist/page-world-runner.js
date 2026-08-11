(() => {
  'use strict';

  const channel = 'openburnbar-safari-page-world-v1';
  const marker = '__openburnbarSafariPageWorldInstalled';
  if (window[marker]) {
    return;
  }
  window[marker] = true;

  const closedShadowRoots = new WeakMap();
  const originalAttachShadow = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function openBurnBarAttachShadow(options) {
    const root = originalAttachShadow.call(this, options);
    if (options.mode === 'closed') {
      closedShadowRoots.set(this, root);
    }
    return root;
  };

  function cloneForMessage(value) {
    const seen = new WeakSet();
    return JSON.parse(
      JSON.stringify(value, (_key, candidate) => {
        if (typeof candidate === 'bigint') {
          return candidate.toString();
        }
        if (typeof candidate === 'function' || typeof candidate === 'symbol') {
          return undefined;
        }
        if (candidate && typeof candidate === 'object') {
          if (seen.has(candidate)) {
            return '[Circular]';
          }
          seen.add(candidate);
        }
        return candidate;
      })
    );
  }

  window.addEventListener('message', async (event) => {
    if (event.source !== window || !event.data || typeof event.data !== 'object') {
      return;
    }
    const request = event.data;
    if (request.channel !== channel || request.direction !== 'request' || typeof request.id !== 'string') {
      return;
    }
    try {
      if (typeof request.source !== 'string' || request.source.length > 100000) {
        throw new Error('JavaScript source is invalid or exceeds 100 KB.');
      }
      const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
      const run = new AsyncFunction(
        'openBurnBar',
        `"use strict";\n${request.source}\n//# sourceURL=openburnbar-safari-user-action.js`
      );
      const result = await run({
        closedShadowRootForHost: (host) => closedShadowRoots.get(host),
        version: 1
      });
      window.postMessage(
        {
          channel,
          direction: 'response',
          id: request.id,
          ok: true,
          result: cloneForMessage(result)
        },
        '*'
      );
    } catch (error) {
      window.postMessage(
        {
          channel,
          direction: 'response',
          id: request.id,
          ok: false,
          error: error instanceof Error ? error.message : String(error)
        },
        '*'
      );
    }
  });
})();
