import { ensurePageWorldRunner, runInPageWorld } from '../src/content/pageWorldBridge';
import { currentPageState, verificationFor } from '../src/content/verification';

describe('page-world bridge and action verification', () => {
  it('injects the packaged page-world runner and correlates responses', async () => {
    vi.spyOn(document.head, 'append').mockImplementation((...nodes: (Node | string)[]) => {
      const node = nodes[0];
      if (node instanceof Node) {
        queueMicrotask(() => node.dispatchEvent(new Event('load')));
      }
    });
    vi.spyOn(window, 'postMessage').mockImplementation((message: unknown) => {
      const request = message as Record<string, unknown>;
      if (request.direction === 'request') {
        queueMicrotask(() => {
          window.dispatchEvent(
            new MessageEvent('message', {
              source: window,
              data: {
                channel: request.channel,
                direction: 'response',
                id: request.id,
                ok: true,
                result: { pageWorld: true }
              }
            })
          );
        });
      }
    });

    await expect(ensurePageWorldRunner((path) => `extension://${path}`)).resolves.toBeUndefined();
    await expect(
      runInPageWorld('return { pageWorld: true };', 500, (path) => `extension://${path}`, new AbortController().signal)
    ).resolves.toEqual({
      pageWorld: true
    });
    expect(document.documentElement.dataset.openburnbarPageWorld).toBe('ready');
  });

  it('captures navigation metadata and redacts verified sensitive values', () => {
    window.history.replaceState({}, '', '/account');
    document.title = 'Account';
    const password = document.createElement('input');
    password.id = 'password';
    password.type = 'password';
    password.value = 'secret';
    document.body.append(password);
    vi.spyOn(password, 'getBoundingClientRect').mockReturnValue({
      x: 2,
      y: 4,
      left: 2,
      top: 4,
      width: 100,
      height: 20,
      right: 102,
      bottom: 24,
      toJSON: () => ({})
    } as DOMRect);
    password.focus();
    const state = currentPageState(() => new Date('2026-08-10T12:00:00Z'));
    expect(state).toMatchObject({
      title: 'Account',
      isTopFrame: true,
      capturedAt: '2026-08-10T12:00:00.000Z'
    });
    const verification = verificationFor(password, { selector: '#password' });
    expect(verification.target?.value).toBe('[redacted]');
    expect(verification.activeElement).toBe('#password');
  });
});
