// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { clearPerfSamples, listPerfSamples } from '../perfMarks.js';
import { useShellStore } from './shellStore.js';

describe('shell route synchronization', () => {
  beforeEach(() => {
    window.history.replaceState(null, '', '/');
    useShellStore.setState({ route: 'overview' });
    clearPerfSamples();
  });

  afterEach(() => {
    window.history.replaceState(null, '', '/');
    clearPerfSamples();
  });

  it('ignores the hashchange echo after setRoute updates the store', () => {
    window.history.replaceState(null, '', '/#/memory');
    useShellStore.setState({ route: 'memory' });

    useShellStore.getState().syncRouteFromHash();

    expect(useShellStore.getState().route).toBe('memory');
    expect(listPerfSamples()).toEqual([]);
  });
});
