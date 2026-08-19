"use client";

import * as React from "react";

/**
 * Console-wide THEMES. Each theme is a complete skin — page/surface backgrounds,
 * ink/text, hairlines, and accent — applied by setting `data-theme` on <html>,
 * which swaps the full token set in styles/globals.css. Every tab consumes those
 * tokens, so the entire console transforms at once. Persisted to localStorage.
 *
 * `paper` is the default (the clean light editorial look) and stays untouched
 * until the member picks another. `preview` is the two-tone chip shown in the
 * switcher: [surface, accent].
 */

export const THEMES = [
  { id: "paper", label: "Paper", scheme: "light", preview: ["#f6f4ef", "#f45b69"] },
  { id: "sand", label: "Sand", scheme: "light", preview: ["#f7f2e9", "#e0892a"] },
  { id: "obsidian", label: "Obsidian", scheme: "dark", preview: ["#0b0d12", "#fb5d6a"] },
  { id: "midnight", label: "Midnight", scheme: "dark", preview: ["#0a0e16", "#4f9cff"] },
  { id: "forest", label: "Forest", scheme: "dark", preview: ["#08110f", "#1fc9a8"] },
] as const;

export type ThemeId = (typeof THEMES)[number]["id"];

export const DEFAULT_THEME: ThemeId = "paper";
const STORAGE_KEY = "burnbar.console.theme";

export function isThemeId(v: unknown): v is ThemeId {
  return typeof v === "string" && THEMES.some((t) => t.id === v);
}

interface ThemeState {
  theme: ThemeId;
  setTheme: (t: ThemeId) => void;
}

const ThemeContext = React.createContext<ThemeState>({
  theme: DEFAULT_THEME,
  setTheme: () => {},
});

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  // Start at the default so server-prerendered HTML matches the first client
  // render (no hydration mismatch); the saved choice is applied after mount.
  const [theme, setThemeState] = React.useState<ThemeId>(DEFAULT_THEME);

  React.useEffect(() => {
    let saved: string | null = null;
    try {
      saved = window.localStorage.getItem(STORAGE_KEY);
    } catch {
      /* private mode / blocked */
    }
    const next = isThemeId(saved) ? saved : DEFAULT_THEME;
    setThemeState(next);
    document.documentElement.dataset.theme = next;
  }, []);

  const setTheme = React.useCallback((t: ThemeId) => {
    if (!isThemeId(t)) return;
    setThemeState(t);
    document.documentElement.dataset.theme = t;
    try {
      window.localStorage.setItem(STORAGE_KEY, t);
    } catch {
      /* non-fatal */
    }
  }, []);

  const value = React.useMemo(() => ({ theme, setTheme }), [theme, setTheme]);
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeState {
  return React.useContext(ThemeContext);
}
