import type {
  TextExpansionEngineRuntimeStatus,
  TextExpansionEngineStartRequest,
  TextExpansionEngineStopRequest,
  TextExpansionNativeStatus,
  TextExpansionSecureFieldContext,
  TextExpansionSnapshot,
  TextExpansionWireSnippet
} from './tauriBridge.js';
import { readTextExpansionConsent } from './textExpansionConsent.js';

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
  textExpansionEngineStatus?(): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineStart?(request: TextExpansionEngineStartRequest): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineStop?(request?: TextExpansionEngineStopRequest): Promise<TextExpansionEngineRuntimeStatus>;
  textExpansionEngineExpand?(request: {
    trigger: string;
    context: TextExpansionSecureFieldContext;
    timeoutMillis?: number;
    requestID?: string;
  }): Promise<{ expanded: boolean; replacement?: string | null }>;
};

const IN_APP_SURFACE = 'in_app_thread' as const;
const MAX_IMPORT_BYTES = 4 * 1024 * 1024;
const MAX_SNIPPETS = 500;

let backend: TextExpansionStorageBackend | null = null;
let backendReady = false;
let nativeItems: TextExpansionSnippet[] = [];
let nativeStatus: TextExpansionNativeStatus | null = null;
let memoryItems: TextExpansionSnippet[] = [];
let backendError: string | null = null;
let allowLocalFallback = true;
let nativeEngineStatus: TextExpansionEngineRuntimeStatus | null = null;
let nativeEngineError: string | null = null;
// The daemon protects its encrypted file with a lock, but renderer calls can
// still complete out of order. Keep the local snapshot in the same order as
// the daemon and fence operations that belong to an older bridge instance.
let nativeMutationQueue: Promise<void> = Promise.resolve();
let nativeEngineMutationQueue: Promise<void> = Promise.resolve();
let backendGeneration = 0;

type NativeMutationContext = {
  backend: TextExpansionStorageBackend;
  generation: number;
};

function nativeMutationContext(): NativeMutationContext | null {
  if (!backendReady || !backend) return null;
  return { backend, generation: backendGeneration };
}

function isCurrentNativeMutation(context: NativeMutationContext): boolean {
  return backendReady && backend === context.backend && backendGeneration === context.generation;
}

function isCurrentBackend(context: NativeMutationContext): boolean {
  return backend === context.backend && backendGeneration === context.generation;
}

function staleNativeMutationError(): Error {
  return new Error('Native text expansion storage changed; retry the operation.');
}

function staleEngineMutationError(): Error {
  return new Error('Native text expansion engine changed; retry the operation.');
}

function enqueueNativeMutation<T>(operation: () => Promise<T>): Promise<T> {
  const next = nativeMutationQueue.then(operation);
  // Keep the queue usable after a rejected operation while preserving the
  // original rejection for the caller that owns this mutation.
  nativeMutationQueue = next.then(() => undefined, () => undefined);
  return next;
}

function enqueueNativeEngineMutation<T>(operation: () => Promise<T>): Promise<T> {
  const next = nativeEngineMutationQueue.then(operation);
  nativeEngineMutationQueue = next.then(() => undefined, () => undefined);
  return next;
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
  return backendReady ? nativeItems : memoryItems;
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
  allowFallback: boolean,
  preserveMemory = false
): void {
  if (backend === next && allowLocalFallback === allowFallback && next !== null && backendReady) return;
  backendGeneration += 1;
  const backendChanged = backend !== next;
  backend = next;
  backendReady = false;
  nativeItems = [];
  nativeStatus = null;
  nativeEngineStatus = null;
  nativeEngineError = null;
  nativeEngineMutationQueue = Promise.resolve();
  if (!preserveMemory || backendChanged) memoryItems = [];
  allowLocalFallback = allowFallback;
  backendError = next || allowFallback ? null : 'Native text expansion storage is unavailable.';
}

export function textExpansionStorageError(): string | null {
  return backendError;
}

/** Hydrate daemon-owned storage. Fixture mode uses memory only and never localStorage. */
export async function hydrateTextExpansionStorage(
  next: TextExpansionStorageBackend | null = backend
): Promise<TextExpansionSnippet[]> {
  if (next !== backend) {
    configureTextExpansionStorageWithPolicy(next, allowLocalFallback);
  }
  if (!backend) {
    return allowLocalFallback ? listSnippets() : [];
  }
  const context: NativeMutationContext = { backend, generation: backendGeneration };
  try {
    const snapshot = await context.backend.textExpansionList();
    if (!isCurrentBackend(context)) return listSnippets();
    nativeItems = fromSnapshot(snapshot);
    nativeStatus = snapshot.nativeStatus ?? null;
    backendReady = true;
    backendError = null;
    return listSnippets();
  } catch (error) {
    if (!isCurrentBackend(context)) return listSnippets();
    backendReady = false;
    backendError = error instanceof Error ? error.message : 'Native text expansion storage unavailable.';
    return listSnippets();
  }
}

/** Last daemon-reported native IME status, or null in fixture/in-app-only mode. */
export function textExpansionNativeStatus(): TextExpansionNativeStatus | null {
  return nativeStatus;
}

/** Last daemon-reported external input-method engine state. */
export function textExpansionEngineStatus(): TextExpansionEngineRuntimeStatus | null {
  return nativeEngineStatus;
}

/** Last engine probe/lifecycle error. In-app expansion remains usable on this path. */
export function textExpansionEngineError(): string | null {
  return nativeEngineError;
}

function engineContext(): NativeMutationContext | null {
  if (!backendReady || !backend) return null;
  return { backend, generation: backendGeneration };
}

function requireEngineContext(
  operation: 'status' | 'start' | 'stop' | 'expand'
): NativeMutationContext {
  const context = engineContext();
  if (!context) throw new Error('Native text expansion engine is unavailable.');
  const method = `textExpansionEngine${operation[0].toUpperCase()}${operation.slice(1)}`;
  if (typeof context.backend[method as keyof TextExpansionStorageBackend] !== 'function') {
    throw new Error('Native text expansion engine is unavailable in this packaged shell.');
  }
  return context;
}

function runtimeTimeout(timeoutMillis: number | undefined, fallback: number): number {
  const timeout = timeoutMillis ?? fallback;
  if (!Number.isInteger(timeout) || timeout < 100 || timeout > 30_000) {
    throw new Error('Text expansion engine timeout must be between 100 and 30000 milliseconds.');
  }
  return timeout;
}

function consentAllowsEngine(): boolean {
  const consent = readTextExpansionConsent();
  return consent?.inAppOnly === true && consent.declinedGlobalCapture === true;
}

export async function hydrateTextExpansionEngineStatus(
  next: TextExpansionStorageBackend | null = backend
): Promise<TextExpansionEngineRuntimeStatus | null> {
  if (next !== backend) configureTextExpansionStorageWithPolicy(next, allowLocalFallback);
  const context = engineContext();
  if (!context?.backend.textExpansionEngineStatus) {
    nativeEngineStatus = null;
    nativeEngineError = null;
    return null;
  }
  try {
    const status = await context.backend.textExpansionEngineStatus();
    if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
    nativeEngineStatus = status;
    nativeEngineError = null;
    return status;
  } catch (error) {
    if (isCurrentNativeMutation(context)) {
      nativeEngineStatus = null;
      nativeEngineError = error instanceof Error ? error.message : 'Native text expansion engine status unavailable.';
    }
    return isCurrentNativeMutation(context) ? nativeEngineStatus : null;
  }
}

export async function startTextExpansionEngine(
  request: Omit<TextExpansionEngineStartRequest, 'consentAcknowledged'> = {}
): Promise<TextExpansionEngineRuntimeStatus> {
  if (!consentAllowsEngine()) throw new Error('Text expansion engine requires explicit consent.');
  const timeoutMillis = runtimeTimeout(request.timeoutMillis, 1_000);
  const context = requireEngineContext('start');
  const start = context.backend.textExpansionEngineStart;
  if (!start) throw new Error('Native text expansion engine is unavailable in this packaged shell.');
  return enqueueNativeEngineMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
    try {
      const status = await start.call(context.backend, { consentAcknowledged: true, timeoutMillis });
      if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
      nativeEngineStatus = status;
      nativeEngineError = null;
      return status;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeEngineError = error instanceof Error ? error.message : 'Native text expansion engine start failed.';
      }
      throw error;
    }
  });
}

export async function stopTextExpansionEngine(
  request: TextExpansionEngineStopRequest = {}
): Promise<TextExpansionEngineRuntimeStatus> {
  const timeoutMillis = runtimeTimeout(request.timeoutMillis, 500);
  const context = requireEngineContext('stop');
  const stop = context.backend.textExpansionEngineStop;
  if (!stop) throw new Error('Native text expansion engine is unavailable in this packaged shell.');
  return enqueueNativeEngineMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
    try {
      const status = await stop.call(context.backend, { timeoutMillis });
      if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
      nativeEngineStatus = status;
      nativeEngineError = null;
      return status;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeEngineError = error instanceof Error ? error.message : 'Native text expansion engine stop failed.';
      }
      throw error;
    }
  });
}

/**
 * Trigger-only external expansion boundary. Secure or uninspectable contexts
 * are denied before the daemon call; no field text, clipboard, or key events
 * can enter this renderer API.
 */
export async function expandTextExpansionEngine(request: {
  trigger: string;
  context: TextExpansionSecureFieldContext;
  timeoutMillis?: number;
  requestID?: string;
}): Promise<string | null> {
  if (!consentAllowsEngine()) throw new Error('Text expansion engine requires explicit consent.');
  // Match the daemon's deny-unless-explicitly-nonsecure policy at the
  // renderer boundary too. An unknown secure-field signal must never reach a
  // bridge implementation that might fail open.
  if (!request.context.inspectable || request.context.isSecureField !== false) return null;
  const context = requireEngineContext('expand');
  const expand = context.backend.textExpansionEngineExpand;
  if (!expand) throw new Error('Native text expansion engine is unavailable in this packaged shell.');
  const trigger = request.trigger.trim();
  if (!trigger || trigger.length > 64) throw new Error('Text expansion trigger is invalid.');
  const timeoutMillis = runtimeTimeout(request.timeoutMillis, 1_000);
  return enqueueNativeEngineMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
    try {
      const result = await expand.call(context.backend, {
        trigger,
        context: request.context,
        timeoutMillis,
        requestID: request.requestID
      });
      if (!isCurrentNativeMutation(context)) throw staleEngineMutationError();
      nativeEngineError = null;
      if (!result.expanded) return null;
      const replacement = result.replacement;
      if (typeof replacement !== 'string' || replacement.length > 128 * 1024) {
        throw new Error('Native text expansion engine returned an invalid replacement.');
      }
      return replacement;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeEngineError = error instanceof Error ? error.message : 'Native text expansion engine request failed.';
      }
      throw error;
    }
  });
}

export function listSnippets(): TextExpansionSnippet[] {
  return sortSnippets(allowLocalFallback || backendReady ? activeItems() : []);
}

export function upsertSnippet(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): TextExpansionSnippet {
  const next = buildSnippet(input);
  const context = nativeMutationContext();
  if (context) {
    nativeItems = replaceItem(nativeItems, next);
    void enqueueNativeMutation(async () => {
      if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
      const stored = fromWireSnippet(await context.backend.textExpansionUpsert(toWireSnippet(next)));
      if (!stored) throw new Error('Native text expansion save returned a deleted snippet.');
      nativeItems = replaceItem(nativeItems, stored);
    }).catch((error) => {
      if (isCurrentNativeMutation(context)) {
        backendError = error instanceof Error ? error.message : 'Native text expansion save failed.';
      }
    });
  } else if (allowLocalFallback) {
    memoryItems = replaceItem(memoryItems, next);
  } else {
    backendError = 'Native text expansion storage is unavailable.';
  }
  return next;
}

export async function upsertSnippetPersisted(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): Promise<TextExpansionSnippet> {
  const next = buildSnippet(input);
  const context = nativeMutationContext();
  if (!context) {
    if (!allowLocalFallback) throw new Error('Native text expansion storage is unavailable.');
    memoryItems = replaceItem(memoryItems, next);
    return next;
  }
  return enqueueNativeMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
    const previous = nativeItems;
    nativeItems = replaceItem(nativeItems, next);
    try {
      const stored = fromWireSnippet(await context.backend.textExpansionUpsert(toWireSnippet(next)));
      if (!stored) throw new Error('Native text expansion save returned a deleted snippet.');
      nativeItems = replaceItem(nativeItems, stored);
      backendError = null;
      return stored;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeItems = previous;
        backendError = error instanceof Error ? error.message : 'Native text expansion save failed.';
      }
      throw error;
    }
  });
}

export function deleteSnippet(id: string): void {
  const context = nativeMutationContext();
  if (context) {
    nativeItems = nativeItems.filter((item) => item.id !== id);
    void enqueueNativeMutation(async () => {
      if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
      const snapshot = await context.backend.textExpansionDelete(id);
      nativeItems = fromSnapshot(snapshot);
      nativeStatus = snapshot.nativeStatus ?? null;
    }).catch((error) => {
      if (isCurrentNativeMutation(context)) {
        backendError = error instanceof Error ? error.message : 'Native text expansion delete failed.';
      }
    });
  } else if (allowLocalFallback) {
    memoryItems = memoryItems.filter((snippet) => snippet.id !== id);
  } else {
    backendError = 'Native text expansion storage is unavailable.';
  }
}

export async function deleteSnippetPersisted(id: string): Promise<void> {
  const context = nativeMutationContext();
  if (!context) {
    if (!allowLocalFallback) throw new Error('Native text expansion storage is unavailable.');
    memoryItems = memoryItems.filter((snippet) => snippet.id !== id);
    return;
  }
  return enqueueNativeMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
    const previous = nativeItems;
    nativeItems = nativeItems.filter((snippet) => snippet.id !== id);
    try {
      const snapshot = await context.backend.textExpansionDelete(id);
      nativeItems = fromSnapshot(snapshot);
      nativeStatus = snapshot.nativeStatus ?? null;
      backendError = null;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeItems = previous;
        backendError = error instanceof Error ? error.message : 'Native text expansion delete failed.';
      }
      throw error;
    }
  });
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
  if (new TextEncoder().encode(json).byteLength > MAX_IMPORT_BYTES) {
    throw new Error('Import exceeds the 4 MiB size limit.');
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error('Invalid JSON.');
  }
  if (!Array.isArray(parsed)) {
    throw new Error('Import must be a JSON array of snippets.');
  }
  if (parsed.length > MAX_SNIPPETS) {
    throw new Error('Import exceeds the 500-snippet limit.');
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
  else if (allowLocalFallback) memoryItems = items;
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
  const context = nativeMutationContext();
  if (context && addedItems.length > 0) {
    void enqueueNativeMutation(async () => {
      if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
      for (const item of addedItems) {
        await context.backend.textExpansionUpsert(toWireSnippet(item));
      }
      const snapshot = await context.backend.textExpansionList();
      nativeItems = fromSnapshot(snapshot);
      nativeStatus = snapshot.nativeStatus ?? null;
    }).catch((error) => {
      if (isCurrentNativeMutation(context)) {
        backendError = error instanceof Error ? error.message : 'Native text expansion import failed.';
      }
    });
  }
  return result;
}

export async function importSnippetsPersisted(json: string): Promise<{ added: number; skipped: number }> {
  if (!backendReady && !allowLocalFallback) {
    throw new Error('Native text expansion storage is unavailable.');
  }
  const context = nativeMutationContext();
  if (!context) return applyImport(json).result;
  return enqueueNativeMutation(async () => {
    if (!isCurrentNativeMutation(context)) throw staleNativeMutationError();
    const previous = nativeItems;
    const { result, addedItems } = applyImport(json);
    try {
      for (const item of addedItems) {
        await context.backend.textExpansionUpsert(toWireSnippet(item));
      }
      const snapshot = await context.backend.textExpansionList();
      nativeItems = fromSnapshot(snapshot);
      nativeStatus = snapshot.nativeStatus ?? null;
      backendError = null;
      return result;
    } catch (error) {
      if (isCurrentNativeMutation(context)) {
        nativeItems = previous;
        backendError = error instanceof Error ? error.message : 'Native text expansion import failed.';
      }
      throw error;
    }
  });
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
