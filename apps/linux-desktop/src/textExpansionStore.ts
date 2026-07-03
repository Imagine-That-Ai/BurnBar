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