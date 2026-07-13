import fs from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  configureTextExpansionStorage,
  deleteSnippet,
  deleteSnippetPersisted,
  expandInAppBuffer,
  exportSnippets,
  findTriggerConflict,
  hydrateTextExpansionStorage,
  importSnippets,
  listSnippets,
  upsertSnippetPersisted,
  upsertSnippet
} from './textExpansionStore.js';
import type { TextExpansionSnapshot, TextExpansionWireSnippet } from './tauriBridge.js';

beforeEach(() => {
  localStorage.clear();
  configureTextExpansionStorage(null);
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

describe('findTriggerConflict', () => {
  it('blocks exact duplicate triggers among enabled snippets', () => {
    const a = upsertSnippet({ title: 'A', trigger: ';;a', body: 'A', enabled: true });
    const conflict = findTriggerConflict(';;a');
    expect(conflict?.id).toBe(a.id);
    expect(findTriggerConflict(';;a', a.id)).toBeNull();
  });

  it('warns on prefix overlap', () => {
    upsertSnippet({ title: 'Long', trigger: ';;sig', body: 'x', enabled: true });
    const conflict = findTriggerConflict(';;s');
    expect(conflict?.trigger).toBe(';;sig');
  });

  it('ignores disabled snippets', () => {
    upsertSnippet({ title: 'Off', trigger: ';;off', body: 'x', enabled: false });
    expect(findTriggerConflict(';;off')).toBeNull();
  });
});

describe('import/export snippets', () => {
  it('round-trips all snippets', () => {
    upsertSnippet({ title: 'One', trigger: ';;one', body: 'ONE', enabled: true });
    upsertSnippet({ title: 'Two', trigger: ';;two', body: 'TWO', enabled: false });
    const json = exportSnippets();
    localStorage.clear();
    expect(importSnippets(json)).toEqual({ added: 2, skipped: 0 });
    expect(listSnippets()).toHaveLength(2);
  });

  it('rejects malformed import', () => {
    expect(() => importSnippets('not json')).toThrow(/Invalid JSON/);
    expect(() => importSnippets('{}')).toThrow(/array/);
    expect(() => importSnippets('[{"title":"x"}]')).toThrow(/shape/);
  });

  it('never overwrites existing triggers silently', () => {
    upsertSnippet({ title: 'Keep', trigger: ';;keep', body: 'K', enabled: true });
    const payload = JSON.stringify([
      { title: 'Dup', trigger: ';;keep', body: 'D', enabled: true },
      { title: 'New', trigger: ';;new', body: 'N', enabled: true }
    ]);
    expect(importSnippets(payload)).toEqual({ added: 1, skipped: 1 });
    expect(listSnippets().find((s) => s.trigger === ';;keep')?.body).toBe('K');
  });
});

describe('text expansion safety pins', () => {
  const runtimeFiles = [
    'src/surfaces/TextExpansionSurface.tsx',
    'src/textExpansionStore.ts',
    'src/textExpansionConsent.ts'
  ];
  const forbidden = ['evdev', 'uinput', 'global keyboard hook', 'CGEventTap', 'RegisterHotKey'];

  it('keeps keydown listeners at zero in pinned files', () => {
    const root = process.cwd();
    for (const file of runtimeFiles) {
      const text = fs.readFileSync(path.join(root, file), 'utf8');
      expect(forbidden.filter((term) => text.includes(term))).toEqual([]);
      expect((text.match(/addEventListener\(['"]keydown/g) ?? []).length).toBe(0);
    }
  });
});

describe('native snapshot storage boundary', () => {
  function backend(initial: TextExpansionWireSnippet[] = []) {
    let snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: new Date(0).toISOString(),
      snippets: [...initial]
    };
    return {
      state: () => snapshot,
      textExpansionList: async () => snapshot,
      textExpansionUpsert: async (snippet: TextExpansionWireSnippet) => {
        snapshot = {
          ...snapshot,
          exportedAt: new Date().toISOString(),
          snippets: [...snapshot.snippets.filter((item) => item.id !== snippet.id), snippet]
        };
        return snippet;
      },
      textExpansionDelete: async (id: string) => {
        snapshot = {
          ...snapshot,
          exportedAt: new Date().toISOString(),
          snippets: snapshot.snippets.map((item) =>
            item.id === id
              ? { ...item, isEnabled: false, deletedAt: new Date().toISOString() }
              : item
          )
        };
        return snapshot;
      }
    };
  }

  it('hydrates daemon storage without migrating renderer state', async () => {
    upsertSnippet({ title: 'Local', trigger: ';;local', body: 'LOCAL', enabled: true });
    const fake = backend();
    await hydrateTextExpansionStorage(fake);
    expect(fake.state().snippets).toHaveLength(0);
    expect(listSnippets()).toHaveLength(0);
    expect(localStorage.getItem('openburnbar.linux.textExpansion.v1')).toBeNull();
  });

  it('uses canonical in-app scope for native CRUD and reflects soft deletion', async () => {
    const fake = backend();
    await hydrateTextExpansionStorage(fake);
    const saved = await upsertSnippetPersisted({
      title: 'Reply',
      trigger: '&&Reply',
      body: 'Thanks',
      enabled: true
    });
    expect(fake.state().snippets[0]?.trigger).toBe('reply');
    expect(fake.state().snippets[0]?.scope.surfaces).toEqual(['in_app_thread']);
    expect(saved.trigger).toBe(';;reply');
    await deleteSnippetPersisted(saved.id);
    expect(listSnippets()).toHaveLength(0);
    expect(fake.state().snippets[0]?.deletedAt).toBeTruthy();
  });
});
