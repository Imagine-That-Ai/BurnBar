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