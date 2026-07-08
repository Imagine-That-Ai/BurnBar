export type TextExpansionSnippet = {
  id: string;
  title: string;
  trigger: string;
  body: string;
  enabled: boolean;
  scope: 'in-app';
  updatedAt: string;
};

const KEY = 'openburnbar.linux.textExpansion.v1';

function load(): TextExpansionSnippet[] {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as TextExpansionSnippet[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function save(items: TextExpansionSnippet[]): void {
  localStorage.setItem(KEY, JSON.stringify(items));
}

export function listSnippets(): TextExpansionSnippet[] {
  return load().sort((a, b) => a.trigger.localeCompare(b.trigger));
}

export function upsertSnippet(
  input: Omit<TextExpansionSnippet, 'id' | 'updatedAt' | 'scope'> & { id?: string }
): TextExpansionSnippet {
  const items = load();
  const now = new Date().toISOString();
  const id = input.id ?? crypto.randomUUID();
  const next: TextExpansionSnippet = {
    id,
    title: input.title.trim(),
    trigger: input.trigger.trim(),
    body: input.body,
    enabled: input.enabled,
    scope: 'in-app',
    updatedAt: now
  };
  const idx = items.findIndex((s) => s.id === id);
  if (idx >= 0) items[idx] = next;
  else items.push(next);
  save(items);
  return next;
}

export function deleteSnippet(id: string): void {
  save(load().filter((s) => s.id !== id));
}

export function expandInAppBuffer(
  buffer: string,
  snippets = listSnippets()
): { output: string; applied?: string } {
  const enabled = snippets.filter((s) => s.enabled);
  for (const s of enabled) {
    if (buffer.endsWith(s.trigger)) {
      return { output: buffer.slice(0, -s.trigger.length) + s.body, applied: s.id };
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

export function exportSnippets(): string {
  return JSON.stringify(listSnippets());
}

export function importSnippets(json: string): { added: number; skipped: number } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(json);
  } catch {
    throw new Error('Invalid JSON.');
  }
  if (!Array.isArray(parsed)) {
    throw new Error('Import must be a JSON array of snippets.');
  }
  const items = load();
  const byId = new Map(items.map((s) => [s.id, s]));
  const byTrigger = new Map(items.map((s) => [s.trigger, s]));
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
    const now = new Date().toISOString();
    const next: TextExpansionSnippet = {
      id,
      title: entry.title.trim(),
      trigger,
      body: entry.body,
      enabled: entry.enabled,
      scope: 'in-app',
      updatedAt: now
    };
    items.push(next);
    byId.set(id, next);
    byTrigger.set(trigger, next);
    added += 1;
  }
  save(items);
  return { added, skipped };
}

export function findTriggerConflict(
  trigger: string,
  excludeId?: string
): TextExpansionSnippet | null {
  const normalized = trigger.trim();
  if (!normalized) return null;
  const enabled = listSnippets().filter((s) => s.enabled && s.id !== excludeId);
  for (const s of enabled) {
    if (s.trigger === normalized || s.trigger.startsWith(normalized) || normalized.startsWith(s.trigger)) {
      return s;
    }
  }
  return null;
}