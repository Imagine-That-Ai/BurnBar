/** Mirrors CommandDeckPalette.swift `matchesSubsequence`. */
export function matchesSubsequence(pattern: string, text: string): boolean {
  if (pattern.length === 0) return true;
  let pi = 0;
  for (let i = 0; i < text.length && pi < pattern.length; i++) {
    if (text[i] === pattern[pi]) pi++;
  }
  return pi === pattern.length;
}

export function routeMatchesQuery(label: string, description: string, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  const title = label.toLowerCase();
  const subtitle = description.toLowerCase();
  return title.includes(q) || subtitle.includes(q) || matchesSubsequence(q, title);
}

/**
 * Rank a route match for palette ordering: exact label, label prefix,
 * label substring, then description/subsequence matches. Lower is better.
 * Keeps ROUTES order within a tier (stable sort). Without this, typing an
 * exact route label like "Memory" could select an earlier route whose
 * description merely mentions the word (e.g. Projects' "code memory scope").
 */
export function routeMatchRank(label: string, description: string, query: string): number {
  const q = query.trim().toLowerCase();
  if (!q) return 3;
  const title = label.toLowerCase();
  if (title === q) return 0;
  if (title.startsWith(q)) return 1;
  if (title.includes(q)) return 2;
  const subtitle = description.toLowerCase();
  if (subtitle.includes(q)) return 3;
  return 4;
}
