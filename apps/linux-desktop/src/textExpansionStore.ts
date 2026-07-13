import type { TextExpansionSnapshot, TextExpansionWireSnippet } from './tauriBridge.js';

/** UI-compatible in-app representation retained for the P14 surface. */
export type TextExpansionSnippet = {
  id: string;
  title: string;
  /** The in-app UI accepts the historical `;;` display prefix. */
  trigger: string;
  body: string;
  enabled: boolean;
  scope: 'in-app';
  updatedAt: string;
  mode?: 'static' | 'llm_rewrite';
  revision?: number;
  createdAt?: string;
  deletedAt?: string | null;
  syncedAt?: string | null;
  sourceDeviceID?: string | null;
};

export type TextExpansionStorageBackend = {
  textExpansionList(): Promise<TextExpansionSnapshot>;
  textExpansionUpsert(snippet: TextExpansionWireSnippet): Promise<TextExpansionWireSnippet>;
  textExpansionDelete(id: string): Promise<TextExpansionSnapshot>;
};

const KEY = 'openburnbar.linux.textExpansion.v1';
const IN_APP_SURFACE = 'in_app_thread' as const;

let backend: TextExpansionStorageBackend | null = null;
let backendReady = false;
let nativeItems: TextExpansionSnippet[] = [];
let backendError: string | null = null;
let allowLocalFallback = true;

function loadLocal(): TextExpansionSnippet[] {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as TextExpansionSnippet[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function saveLocal(items: TextExpansionSnippet[]): void {
  localStorage.setItem(KEY, JSON.stringify(items));
}

function now(): string {
  return new Date().toISOString();
}

function canonicalTrigger(raw: string): string {
  let value = raw.trim().toLowerCase();
  while (value.startsWith('&&')) value = value.slice(2);
  while (value.startsWith(';;')) value = value.slice(2);
  return value;
}

function displayTrigger(raw: string): string {
  return `;;${canonicalTrigger(raw)}`;
}

function toWireSnippet(snippet: TextExpansionSnippet): TextExpansionWireSnippet {
  return {
    id: snippet.id,
    title: snippet.title,
    trigger: canonicalTrigger(snippet.trigger),
    body: snippet.body,
    mode: snippet.mode ?? 'static',
    isEnabled: snippet.enabled,
    scope: { surfaces: [IN_APP_SURFACE], bundleIdentifiers: [], threadIDs: [] },
    revision: Math.max(1, snippet.revision ?? 1),
    createdAt: snippet.createdAt ?? snippet.updatedAt,
    updatedAt: snippet.updatedAt,
    deletedAt: snippet.deletedAt ?? null,
    syncedAt: snippet.syncedAt ?? null,
    sourceDeviceID: snippet.sourceDeviceID ?? null
  };
}

function fromWireSnippet(snippet: TextExpansionWireSnippet): TextExpansionSnippet | null {
  if (snippet.deletedAt) return null;
  if (!snippet.id || !snippet.title || !snippet.updatedAt || !canonicalTrigger(snippet.trigger)) return null;
  return {
    id: snippet.id,
    title: snippet.title,
    trigger: displayTrigger(snippet.trigger),
    body: snippet.body,
    enabled: snippet.isEnabled,
    scope: 'in-app',
    updatedAt: snippet.updatedAt,
    mode: snippet.mode,
    revision: snippet.revision,
    createdAt: snippet.createdAt,
    deletedAt: snippet.deletedAt ?? null,
    syncedAt: snippet.syncedAt ?? null,
    sourceDeviceID: snippet.sourceDeviceID ?? null
  };
}

function fromSnapshot(snapshot: TextExpansionSnapshot): TextExpansionSnippet[] {
  return snapshot.snippets.map(fromWireSnippet).filter((item): item is TextExpansionSnippet => item !== null);
}

function activeItems(): TextExpansionSnippet[] {
  return backendReady ? nativeItems : loadLocal();
}

function sortSnippets(items: TextExpansionSnippet[]): TextExpansionSnippet[] {
  return [...items].sort((a, b) => a.trigger.localeCompare(b.trigger));
}

function replaceItem(items: TextExpansionSnippet[], next: TextExpansionSnippet): TextExpansionSnippet[] {
  const index = items.findIndex((item) => item.id === next.id);
  if (index < 0) return [...items, next];
  const copy = [...items];
  copy[index] = next;
  return copy;
}

function buildSnippet(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): TextExpansionSnippet {
  const timestamp = now();
  return {
    id: input.id ?? crypto.randomUUID(),
    title: input.title.trim(),
    trigger: input.trigger.trim(),
    body: input.body,
    enabled: input.enabled,
    scope: 'in-app',
    updatedAt: timestamp,
    mode: input.mode ?? 'static',
    revision: input.revision ?? 1,
    createdAt: input.createdAt ?? timestamp,
    deletedAt: null,
    syncedAt: null,
    sourceDeviceID: input.sourceDeviceID ?? null
  };
}

/** Select the native snapshot backend, or pass null for browser/fixture fallback. */
export function configureTextExpansionStorage(next: TextExpansionStorageBackend | null): void {
  configureTextExpansionStorageWithPolicy(next, true);
}

export function configureTextExpansionStorageWithPolicy(
  next: TextExpansionStorageBackend | null,
  allowFallback: boolean
): void {
  if (backend === next && allowLocalFallback === allowFallback && (next === null || backendReady)) return;
  backend = next;
  backendReady = false;
  nativeItems = [];
  allowLocalFallback = allowFallback;
  backendError = next || allowFallback ? null : 'Native text expansion storage is unavailable.';
}

export function textExpansionStorageError(): string | null {
  return backendError;
}

/** Hydrate native storage and migrate the old localStorage representation once. */
export async function hydrateTextExpansionStorage(
  next: TextExpansionStorageBackend | null = backend
): Promise<TextExpansionSnippet[]> {
  if (next !== backend) {
    configureTextExpansionStorageWithPolicy(next, allowLocalFallback);
  }
  if (!backend) {
    return allowLocalFallback ? listSnippets() : [];
  }
  try {
    let snapshot = await backend.textExpansionList();
    let items = fromSnapshot(snapshot);
    const localItems = loadLocal();
    if (items.length === 0 && localItems.length > 0) {
      for (const item of localItems) {
        await backend.textExpansionUpsert(toWireSnippet(item));
      }
      snapshot = await backend.textExpansionList();
      items = fromSnapshot(snapshot);
      try {
        localStorage.removeItem(KEY);
      } catch {
        // Native persistence succeeded; retaining a failed cleanup is harmless.
      }
    }
    nativeItems = items;
    backendReady = true;
    backendError = null;
    return listSnippets();
  } catch (error) {
    backendReady = false;
    backendError = error instanceof Error ? error.message : 'Native text expansion storage unavailable.';
    return listSnippets();
  }
}

export function listSnippets(): TextExpansionSnippet[] {
  return sortSnippets(allowLocalFallback || backendReady ? activeItems() : []);
}

export function upsertSnippet(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): TextExpansionSnippet {
  const next = buildSnippet(input);
  if (backendReady && backend) {
    nativeItems = replaceItem(nativeItems, next);
    void backend.textExpansionUpsert(toWireSnippet(next)).catch((error) => {
      backendError = error instanceof Error ? error.message : 'Native text expansion save failed.';
    });
  } else if (allowLocalFallback) {
    saveLocal(replaceItem(loadLocal(), next));
  } else {
    backendError = 'Native text expansion storage is unavailable.';
  }
  return next;
}

export async function upsertSnippetPersisted(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): Promise<TextExpansionSnippet> {
  const next = buildSnippet(input);
  if (!backendReady || !backend) {
    if (!allowLocalFallback) throw new Error('Native text expansion storage is unavailable.');
    saveLocal(replaceItem(loadLocal(), next));
    return next;
  }
  const previous = nativeItems;
  nativeItems = replaceItem(nativeItems, next);
  try {
    const stored = fromWireSnippet(await backend.textExpansionUpsert(toWireSnippet(next)));
    if (!stored) throw new Error('Native text expansion save returned a deleted snippet.');
    nativeItems = replaceItem(nativeItems, stored);
    backendError = null;
    return stored;
  } catch (error) {
    nativeItems = previous;
    backendError = error instanceof Error ? error.message : 'Native text expansion save failed.';
    throw error;
  }
}

export function deleteSnippet(id: string): void {
  if (backendReady && backend) {
    nativeItems = nativeItems.filter((item) => item.id !== id);
    void backend.textExpansionDelete(id).catch((error) => {
      backendError = error instanceof Error ? error.message : 'Native text expansion delete failed.';
    });
  } else if (allowLocalFallback) {
    saveLocal(loadLocal().filter((snippet) => snippet.id !== id));
  } else {
    backendError = 'Native text expansion storage is unavailable.';
  }
}

export async function deleteSnippetPersisted(id: string): Promise<void> {
  if (!backendReady || !backend) {
    if (!allowLocalFallback) throw new Error('Native text expansion storage is unavailable.');
    saveLocal(loadLocal().filter((snippet) => snippet.id !== id));
    return;
  }
  const previous = nativeItems;
  nativeItems = nativeItems.filter((snippet) => snippet.id !== id);
  try {
    const snapshot = await backend.textExpansionDelete(id);
    nativeItems = fromSnapshot(snapshot);
    backendError = null;
  } catch (error) {
    nativeItems = previous;
    backendError = error instanceof Error ? error.message : 'Native text expansion delete failed.';
    throw error;
  }
}

export function expandInAppBuffer(
  buffer: string,
  snippets = listSnippets()
): { output: string; applied?: string } {
  const enabled = snippets.filter((snippet) => snippet.enabled);
  for (const snippet of enabled) {
    if (buffer.endsWith(snippet.trigger)) {
      return {
        output: buffer.slice(0, -snippet.trigger.length) + snippet.body,
        applied: snippet.id
      };
    }
  }
  return { output: buffer };
}

function isSnippetShape(value: unknown): value is Omit<TextExpansionSnippet, 'id' | 'updatedAt'> & { id?: string } {
  if (!value || typeof value !== 'object') return false;
  const row = value as Record<string, unknown>;
  return (
    typeof row.title === 'string' &&
    typeof row.trigger === 'string' &&
    typeof row.body === 'string' &&
    typeof row.enabled === 'boolean' &&
    (row.scope === undefined || row.scope === 'in-app')
  );
}

type ImportResult = { result: { added: number; skipped: number }; addedItems: TextExpansionSnippet[] };

function applyImport(json: string): ImportResult {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error('Invalid JSON.');
  }
  if (!Array.isArray(parsed)) {
    throw new Error('Import must be a JSON array of snippets.');
  }
  const items = activeItems();
  const byId = new Map(items.map((snippet) => [snippet.id, snippet]));
  const byTrigger = new Map(items.map((snippet) => [snippet.trigger, snippet]));
  const addedItems: TextExpansionSnippet[] = [];
  let added = 0;
  let skipped = 0;
  for (const entry of parsed) {
    if (!isSnippetShape(entry)) {
      throw new Error('Invalid snippet shape in import file.');
    }
    const trigger = entry.trigger.trim();
    if (!trigger) {
      skipped += 1;
      continue;
    }
    const id = typeof entry.id === 'string' && entry.id ? entry.id : crypto.randomUUID();
    if (byId.has(id) || byTrigger.has(trigger)) {
      skipped += 1;
      continue;
    }
    const next = buildSnippet({
      id,
      title: entry.title,
      trigger,
      body: entry.body,
      enabled: entry.enabled,
      mode: entry.mode,
      revision: entry.revision,
      createdAt: entry.createdAt,
      sourceDeviceID: entry.sourceDeviceID
    });
    items.push(next);
    addedItems.push(next);
    byId.set(id, next);
    byTrigger.set(trigger, next);
    added += 1;
  }
  if (backendReady) nativeItems = items;
  else if (allowLocalFallback) saveLocal(items);
  return { result: { added, skipped }, addedItems };
}

export function exportSnippets(): string {
  return JSON.stringify(listSnippets());
}

export function importSnippets(json: string): { added: number; skipped: number } {
  if (!backendReady && !allowLocalFallback) {
    throw new Error('Native text expansion storage is unavailable.');
  }
  const { result, addedItems } = applyImport(json);
  if (backendReady && backend) {
    void Promise.all(addedItems.map((item) => backend!.textExpansionUpsert(toWireSnippet(item)))).catch((error) => {
      backendError = error instanceof Error ? error.message : 'Native text expansion import failed.';
    });
  }
  return result;
}

export async function importSnippetsPersisted(json: string): Promise<{ added: number; skipped: number }> {
  if (!backendReady && !allowLocalFallback) {
    throw new Error('Native text expansion storage is unavailable.');
  }
  const previous = nativeItems;
  const { result, addedItems } = applyImport(json);
  if (!backendReady || !backend) return result;
  try {
    for (const item of addedItems) {
      await backend.textExpansionUpsert(toWireSnippet(item));
    }
    const snapshot = await backend.textExpansionList();
    nativeItems = fromSnapshot(snapshot);
    backendError = null;
    return result;
  } catch (error) {
    nativeItems = previous;
    backendError = error instanceof Error ? error.message : 'Native text expansion import failed.';
    throw error;
  }
}

export function findTriggerConflict(
  trigger: string,
  excludeId?: string
): TextExpansionSnippet | null {
  const normalized = trigger.trim();
  if (!normalized) return null;
  const enabled = listSnippets().filter((snippet) => snippet.enabled && snippet.id !== excludeId);
  for (const snippet of enabled) {
    if (
      snippet.trigger === normalized ||
      snippet.trigger.startsWith(normalized) ||
      normalized.startsWith(snippet.trigger)
    ) {
      return snippet;
    }
  }
  return null;
}
