import fs from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  configureTextExpansionStorage,
  deleteSnippet,
  deleteSnippetPersisted,
  expandInAppBuffer,
  expandTextExpansionEngine,
  exportSnippets,
  findTriggerConflict,
  hydrateTextExpansionEngineStatus,
  hydrateTextExpansionStorage,
  importSnippets,
  listSnippets,
  startTextExpansionEngine,
  stopTextExpansionEngine,
  textExpansionEngineError,
  textExpansionEngineStatus,
  upsertSnippetPersisted,
  upsertSnippet
} from './textExpansionStore.js';
import { configureTextExpansionConsentStorage, writeTextExpansionConsent } from './textExpansionConsent.js';
import type { TextExpansionSnapshot, TextExpansionWireSnippet } from './tauriBridge.js';
import type { TextExpansionStorageBackend } from './textExpansionStore.js';

beforeEach(() => {
  localStorage.clear();
  configureTextExpansionStorage(null);
  configureTextExpansionConsentStorage(null, true);
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
    configureTextExpansionStorage(null);
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

  it('serializes native mutations so a late delete snapshot cannot clobber a newer upsert', async () => {
    const keep: TextExpansionWireSnippet = {
      id: 'keep',
      title: 'Keep',
      trigger: 'keep',
      body: 'old',
      mode: 'static',
      isEnabled: true,
      scope: { surfaces: ['in_app_thread'], bundleIdentifiers: [], threadIDs: [] },
      revision: 1,
      createdAt: new Date(0).toISOString(),
      updatedAt: new Date(0).toISOString(),
      deletedAt: null,
      syncedAt: null,
      sourceDeviceID: null
    };
    const remove: TextExpansionWireSnippet = {
      ...keep,
      id: 'remove',
      title: 'Remove',
      trigger: 'remove'
    };
    let snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: new Date(0).toISOString(),
      snippets: [keep, remove]
    };
    const calls: string[] = [];
    let releaseDelete: (() => void) | undefined;
    const staleDeleteSnapshot: TextExpansionSnapshot = {
      ...snapshot,
      snippets: [{ ...remove, isEnabled: false, deletedAt: new Date(1).toISOString() }, keep]
    };
    const fake: TextExpansionStorageBackend = {
      textExpansionList: async () => snapshot,
      textExpansionUpsert: async (snippet) => {
        calls.push(`upsert:${snippet.id}`);
        snapshot = { ...snapshot, snippets: [...snapshot.snippets.filter((item) => item.id !== snippet.id), snippet] };
        return snippet;
      },
      textExpansionDelete: (id) => {
        calls.push(`delete:${id}`);
        return new Promise((resolve) => {
          releaseDelete = () => resolve(staleDeleteSnapshot);
        });
      }
    };

    await hydrateTextExpansionStorage(fake);
    const deletePromise = deleteSnippetPersisted('remove');
    const updatePromise = upsertSnippetPersisted({
      id: 'keep',
      title: 'Keep',
      trigger: ';;keep',
      body: 'new',
      enabled: true
    });
    await Promise.resolve();
    expect(calls).toEqual(['delete:remove']);
    releaseDelete?.();
    await Promise.all([deletePromise, updatePromise]);

    expect(calls).toEqual(['delete:remove', 'upsert:keep']);
    expect(listSnippets()).toEqual([
      expect.objectContaining({ id: 'keep', body: 'new' })
    ]);
  });
});

describe('native input-method engine boundary', () => {
  function engineBackend() {
    const snapshot: TextExpansionSnapshot = {
      schemaVersion: 1,
      exportedAt: new Date(0).toISOString(),
      snippets: []
    };
    let status: NonNullable<ReturnType<typeof textExpansionEngineStatus>> = {
      state: 'not_running',
      engineID: null,
      executablePath: null,
      registration: 'registered',
      supportsExternalExpansion: true,
      detail: 'ready',
      checkedAt: new Date(0).toISOString()
    };
    const calls: string[] = [];
    const backend: TextExpansionStorageBackend = {
      textExpansionList: async () => snapshot,
      textExpansionUpsert: async (snippet) => snippet,
      textExpansionDelete: async () => snapshot,
      textExpansionEngineStatus: async () => status,
      textExpansionEngineStart: async (request) => {
        calls.push(`start:${request.consentAcknowledged}:${request.timeoutMillis}`);
        status = { ...status, state: 'running', detail: 'active' };
        return status;
      },
      textExpansionEngineStop: async (request) => {
        calls.push(`stop:${request?.timeoutMillis}`);
        status = { ...status, state: 'not_running', detail: 'stopped' };
        return status;
      },
      textExpansionEngineExpand: async () => ({ expanded: true, replacement: 'expanded' })
    };
    return { backend, calls };
  }

  it('hydrates and serializes consent-gated engine lifecycle transitions', async () => {
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    const fake = engineBackend();
    await hydrateTextExpansionStorage(fake.backend);
    await hydrateTextExpansionEngineStatus(fake.backend);

    expect(textExpansionEngineStatus()?.state).toBe('not_running');
    await expect(startTextExpansionEngine({ timeoutMillis: 250 })).resolves.toMatchObject({ state: 'running' });
    await expect(stopTextExpansionEngine({ timeoutMillis: 300 })).resolves.toMatchObject({ state: 'not_running' });
    expect(fake.calls).toEqual(['start:true:250', 'stop:300']);
    expect(textExpansionEngineError()).toBeNull();
  });

  it('fails closed without consent and before calling an uninspectable context', async () => {
    const fake = engineBackend();
    await hydrateTextExpansionStorage(fake.backend);
    await expect(startTextExpansionEngine()).rejects.toThrow(/explicit consent/i);
    await expect(expandTextExpansionEngine({
      trigger: 'reply',
      context: { inspectable: true, isSecureField: false }
    })).rejects.toThrow(/explicit consent/i);
    expect(fake.calls).toEqual([]);
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    await expect(expandTextExpansionEngine({
      trigger: 'reply',
      context: { inspectable: false, isSecureField: false }
    })).resolves.toBeNull();
    expect(fake.calls).toEqual([]);
  });

  it('ignores a late status response from a replaced native bridge', async () => {
    let release!: (status: NonNullable<ReturnType<typeof textExpansionEngineStatus>>) => void;
    const fake = engineBackend();
    fake.backend.textExpansionEngineStatus = () => new Promise((resolve) => { release = resolve; });
    await hydrateTextExpansionStorage(fake.backend);
    const pending = hydrateTextExpansionEngineStatus(fake.backend);
    await Promise.resolve();
    configureTextExpansionStorage(null);
    release({
      state: 'running',
      registration: 'registered',
      supportsExternalExpansion: true,
      detail: 'stale',
      checkedAt: new Date(1).toISOString()
    });
    await pending;
    expect(textExpansionEngineStatus()).toBeNull();
    expect(textExpansionEngineError()).toBeNull();
  });
});
