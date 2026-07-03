import { beforeEach, describe, expect, it } from 'vitest';
import { expandInAppBuffer, upsertSnippet, listSnippets, deleteSnippet } from './textExpansionStore.js';

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
});