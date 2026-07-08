import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { routeMatchRank, routeMatchesQuery } from '../commandPaletteMatch.js';
import { pushCommandPaletteRecent, readCommandPaletteRecents } from '../commandPaletteRecents.js';
import { ROUTES, type RouteMeta, type ShellRoute } from '../routes.js';
import { useShellStore } from '../state/shellStore.js';
import './CommandPalette.css';

type PaletteRow =
  | { kind: 'route'; route: RouteMeta; shortcut: number | null }
  | { kind: 'recent'; query: string };

function routeIconLabel(id: ShellRoute): string {
  const words = id.split('-').filter(Boolean);
  if (words.length >= 2) {
    return (words[0][0] + words[1][0]).toUpperCase();
  }
  return id.slice(0, 2).toUpperCase();
}

function filteredRecents(query: string, recents: string[]): string[] {
  const q = query.trim().toLowerCase();
  if (!q) return recents;
  return recents.filter((r) => r.toLowerCase().includes(q));
}

type CommandPaletteProps = {
  open: boolean;
  onClose: () => void;
};

export function CommandPalette({ open, onClose }: CommandPaletteProps) {
  const setRoute = useShellStore((s) => s.setRoute);
  const [query, setQuery] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [inputFocused, setInputFocused] = useState(false);
  const [recents, setRecents] = useState<string[]>(() => readCommandPaletteRecents());
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const navigateRoutes = useMemo(
    () =>
      ROUTES.filter((r) => routeMatchesQuery(r.label, r.description, query)).sort(
        (a, b) =>
          routeMatchRank(a.label, a.description, query) -
          routeMatchRank(b.label, b.description, query)
      ),
    [query]
  );

  const searchRows = useMemo(() => filteredRecents(query, recents), [query, recents]);

  const flatRows: PaletteRow[] = useMemo(() => {
    const rows: PaletteRow[] = navigateRoutes.map((route, index) => ({
      kind: 'route',
      route,
      shortcut: index < 9 ? index + 1 : null
    }));
    for (const recent of searchRows) {
      rows.push({ kind: 'recent', query: recent });
    }
    return rows;
  }, [navigateRoutes, searchRows]);

  const resetState = useCallback(() => {
    setQuery('');
    setSelectedIndex(0);
    setRecents(readCommandPaletteRecents());
  }, []);

  useEffect(() => {
    if (!open) return;
    resetState();
    const id = window.requestAnimationFrame(() => inputRef.current?.focus());
    return () => window.cancelAnimationFrame(id);
  }, [open, resetState]);

  useEffect(() => {
    setSelectedIndex(0);
  }, [query, navigateRoutes.length, searchRows.length]);

  useEffect(() => {
    if (!open || !listRef.current) return;
    const selected = listRef.current.querySelector<HTMLElement>('[data-selected="true"]');
    if (selected && typeof selected.scrollIntoView === 'function') {
      selected.scrollIntoView({ block: 'nearest' });
    }
  }, [open, selectedIndex]);

  const activateRow = useCallback(
    (row: PaletteRow) => {
      if (row.kind === 'route') {
        if (query.trim()) pushCommandPaletteRecent(query);
        setRoute(row.route.id);
        onClose();
        return;
      }
      setQuery(row.query);
      pushCommandPaletteRecent(row.query);
      setRecents(readCommandPaletteRecents());
      inputRef.current?.focus();
    },
    [onClose, query, setRoute]
  );

  const activateSelected = useCallback(() => {
    const row = flatRows[selectedIndex];
    if (row) activateRow(row);
  }, [activateRow, flatRows, selectedIndex]);

  const handleDialogKeyDown = (event: KeyboardEvent) => {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      if (flatRows.length === 0) return;
      setSelectedIndex((i) => Math.min(i + 1, flatRows.length - 1));
      return;
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault();
      if (flatRows.length === 0) return;
      setSelectedIndex((i) => Math.max(i - 1, 0));
      return;
    }
    if (event.key === 'Escape') {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      activateSelected();
    }
  };

  if (!open) return null;

  const trimmed = query.trim();
  const showEmpty = flatRows.length === 0 && trimmed.length > 0;
  const navigateCount = navigateRoutes.length;

  return (
    <div
      className="command-palette-backdrop"
      role="presentation"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        className="command-palette"
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        onKeyDown={handleDialogKeyDown}
      >
        <div
          className={`command-palette-search${inputFocused ? ' command-palette-search--focused' : ''}`}
        >
          <span className="command-palette-search-icon" aria-hidden="true">
            ⌕
          </span>
          <input
            ref={inputRef}
            className="command-palette-input"
            type="search"
            value={query}
            placeholder="Jump to section or search…"
            aria-label="Search routes and recent queries"
            autoComplete="off"
            onFocus={() => setInputFocused(true)}
            onBlur={() => setInputFocused(false)}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
                e.preventDefault();
                handleDialogKeyDown(e);
              }
              if (e.key === 'Enter') {
                e.preventDefault();
                activateSelected();
              }
            }}
          />
          {query ? (
            <button
              type="button"
              className="command-palette-clear"
              aria-label="Clear search"
              onClick={() => {
                setQuery('');
                inputRef.current?.focus();
              }}
            >
              ✕
            </button>
          ) : null}
        </div>

        <div className="command-palette-results" ref={listRef}>
          {flatRows.map((row, index) => (
            <div key={row.kind === 'route' ? row.route.id : `recent-${row.query}`}>
              {row.kind === 'route' && index === 0 ? (
                <div className="command-palette-section-label">Navigate</div>
              ) : null}
              {row.kind === 'recent' && index === navigateCount ? (
                <div className="command-palette-section-label">Search</div>
              ) : null}
              <button
                type="button"
                className="command-palette-row"
                data-selected={selectedIndex === index}
                onMouseEnter={() => setSelectedIndex(index)}
                onClick={() => activateRow(row)}
              >
                <span className="command-palette-row-icon" aria-hidden="true">
                  {row.kind === 'route' ? routeIconLabel(row.route.id) : '↺'}
                </span>
                <span className="command-palette-row-body">
                  <span className="command-palette-row-title">
                    {row.kind === 'route' ? row.route.label : row.query}
                  </span>
                  <span className="command-palette-row-subtitle">
                    {row.kind === 'route' ? row.route.description : 'Recent search'}
                  </span>
                </span>
                {row.kind === 'route' && row.shortcut != null ? (
                  <span className="command-palette-row-shortcut">⌘{row.shortcut}</span>
                ) : null}
              </button>
            </div>
          ))}

          {showEmpty ? (
            <div className="command-palette-empty">No results for &ldquo;{trimmed}&rdquo;</div>
          ) : null}
        </div>
      </div>
    </div>
  );
}