import { SafariExtensionError } from '../shared/errors';

const CHANNEL = 'openburnbar-safari-page-world-v1';
let runnerPromise: Promise<void> | undefined;

export function ensurePageWorldRunner(getURL: (path: string) => string): Promise<void> {
  runnerPromise ??= new Promise<void>((resolve, reject) => {
    if (document.documentElement.dataset.openburnbarPageWorld === 'ready') {
      resolve();
      return;
    }
    const script = document.createElement('script');
    script.src = getURL('page-world-runner.js');
    script.async = false;
    script.dataset.openburnbarBridge = 'true';
    script.addEventListener('load', () => {
      script.remove();
      document.documentElement.dataset.openburnbarPageWorld = 'ready';
      resolve();
    });
    script.addEventListener('error', () => {
      script.remove();
      reject(new SafariExtensionError('page_world_unavailable', 'Safari blocked the page-world bridge.'));
    });
    (document.head ?? document.documentElement).append(script);
  });
  return runnerPromise;
}

export async function runInPageWorld(
  source: string,
  timeoutMs: number,
  getURL: (path: string) => string,
  signal: AbortSignal
): Promise<unknown> {
  await ensurePageWorldRunner(getURL);
  if (signal.aborted) {
    throw new DOMException('The Safari action was aborted.', 'AbortError');
  }
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = window.setTimeout(() => {
      cleanup();
      reject(new SafariExtensionError('javascript_timeout', 'Page-world JavaScript timed out.', { retryable: true }));
    }, timeoutMs);

    function cleanup(): void {
      window.clearTimeout(timeout);
      window.removeEventListener('message', onMessage);
      signal.removeEventListener('abort', onAbort);
    }

    function onAbort(): void {
      cleanup();
      reject(new DOMException('The Safari action was aborted.', 'AbortError'));
    }

    function onMessage(event: MessageEvent): void {
      if (event.source !== window || !event.data || typeof event.data !== 'object') {
        return;
      }
      const data = event.data as Record<string, unknown>;
      if (data.channel !== CHANNEL || data.direction !== 'response' || data.id !== id) {
        return;
      }
      cleanup();
      if (data.ok === true) {
        resolve(data.result);
      } else {
        reject(
          new SafariExtensionError(
            'page_world_javascript_failed',
            typeof data.error === 'string' ? data.error : 'Page-world JavaScript failed.'
          )
        );
      }
    }

    window.addEventListener('message', onMessage);
    signal.addEventListener('abort', onAbort, { once: true });
    window.postMessage(
      {
        channel: CHANNEL,
        direction: 'request',
        id,
        source
      },
      '*'
    );
  });
}
