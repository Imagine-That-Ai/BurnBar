import { beforeEach, describe, expect, it } from 'vitest';
import { deleteSnippet, expandInAppBuffer, listSnippets, upsertSnippet } from './textExpansionStore.js';

beforeEach(() => {
  localStorage.clear();
});

describe('text expansion v1', () => {
  it('expands trailing trigger in buffer only', () => {
    upsertSnippet({ title: 'sig', trigger: ';;sig', body: '— OB', enabled: true });
    const out = expandInAppBuffer('hello ;;sig');
    expect(out.output).toBe('hello — OB');
  });

  it('persists snippets', () => {
    upsertSnippet({ title: 'a', trigger: ';a', body: 'A', enabled: true });
    expect(listSnippets()).toHaveLength(1);
    deleteSnippet(listSnippets()[0].id);
    expect(listSnippets()).toHaveLength(0);
  });

  it('does not expand disabled snippets', () => {
    upsertSnippet({ title: 'off', trigger: ';off', body: 'OFF', enabled: false });
    expect(expandInAppBuffer('test ;off').output).toBe('test ;off');
  });

  it('only substitutes the supplied in-app buffer', () => {
    upsertSnippet({ title: 'local', trigger: ';local', body: 'LOCAL', enabled: true });
    const source = 'outside-app ;local';
    const result = expandInAppBuffer(source);
    expect(result.output).toBe('outside-app LOCAL');
    expect(window.localStorage.getItem('capturedGlobalKeys')).toBeNull();
  });
});
