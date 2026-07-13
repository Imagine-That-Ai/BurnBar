// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { applyReducedMotionClass } from './a11y.js';

type FakeMediaQuery = MediaQueryList & {
  setMatches(value: boolean): void;
};

function stubMatchMedia(matches: boolean): FakeMediaQuery {
  let currentMatches = matches;
  let changeHandler: ((event: MediaQueryListEvent) => void) | undefined;
  const query = {
    get matches() {
      return currentMatches;
    },
    media: '(prefers-reduced-motion: reduce)',
    onchange: null,
    addEventListener: vi.fn((_type: string, listener: (event: MediaQueryListEvent) => void) => {
      changeHandler = listener;
    }),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
    setMatches(value: boolean) {
      currentMatches = value;
      changeHandler?.({ matches: value } as MediaQueryListEvent);
    }
  } as unknown as FakeMediaQuery;

  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    writable: true,
    value: vi.fn(() => query)
  });
  return query;
}

afterEach(() => {
  document.body.classList.remove('reduced-motion');
  vi.restoreAllMocks();
});

describe('accessibility preference lifecycle', () => {
  it('applies the initial reduced-motion preference and follows live changes', () => {
    const query = stubMatchMedia(false);
    const remove = applyReducedMotionClass();

    expect(document.body.classList.contains('reduced-motion')).toBe(false);
    query.setMatches(true);
    expect(document.body.classList.contains('reduced-motion')).toBe(true);
    query.setMatches(false);
    expect(document.body.classList.contains('reduced-motion')).toBe(false);

    remove();
    expect(query.removeEventListener).toHaveBeenCalledWith('change', expect.any(Function));
  });

  it('uses the legacy listener API when WebKitGTK lacks event listeners', () => {
    const query = stubMatchMedia(true);
    query.addEventListener = undefined as unknown as typeof query.addEventListener;
    const remove = applyReducedMotionClass();

    expect(document.body.classList.contains('reduced-motion')).toBe(true);
    expect(query.addListener).toHaveBeenCalledWith(expect.any(Function));
    remove();
    expect(query.removeListener).toHaveBeenCalledWith(expect.any(Function));
  });
});
