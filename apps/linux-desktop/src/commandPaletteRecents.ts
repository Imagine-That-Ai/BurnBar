export const COMMAND_PALETTE_RECENTS_KEY = 'openburnbar.linux.commandPalette.recents.v1';
const MAX_RECENTS = 6;

export function readCommandPaletteRecents(): string[] {
  try {
    const raw = localStorage.getItem(COMMAND_PALETTE_RECENTS_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is string => typeof item === 'string').slice(0, MAX_RECENTS);
  } catch {
    return [];
  }
}

export function pushCommandPaletteRecent(query: string): void {
  const trimmed = query.trim();
  if (!trimmed) return;
  const existing = readCommandPaletteRecents().filter((q) => q !== trimmed);
  const next = [trimmed, ...existing].slice(0, MAX_RECENTS);
  localStorage.setItem(COMMAND_PALETTE_RECENTS_KEY, JSON.stringify(next));
}