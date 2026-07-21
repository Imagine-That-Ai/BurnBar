import { useEffect, useId, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from 'react';
import { useShellStore, type ShellSkin } from '../state/shellStore.js';

type AppearanceMode = 'system' | 'light' | 'dark';

const APPEARANCE_KEY = 'openburnbar.linux.appearanceMode.v1';

const APPEARANCE_OPTIONS: { id: AppearanceMode; label: string }[] = [
  { id: 'system', label: 'Match system' },
  { id: 'light', label: 'Light' },
  { id: 'dark', label: 'Dark' }
];

const SKIN_OPTIONS: { id: ShellSkin; label: string }[] = [
  { id: 'editorial', label: 'Editorial' },
  { id: 'aurora', label: 'Aurora' }
];

function readAppearanceMode(): AppearanceMode {
  try {
    const v = localStorage.getItem(APPEARANCE_KEY);
    if (v === 'light' || v === 'dark') return v;
    return 'system';
  } catch {
    return 'system';
  }
}

function applyAppearanceMode(mode: AppearanceMode): void {
  try {
    localStorage.setItem(APPEARANCE_KEY, mode);
  } catch {
    // convenience only
  }
  const root = document.documentElement;
  if (mode === 'light') {
    root.dataset.appearance = 'light';
  } else if (mode === 'dark') {
    root.dataset.appearance = 'dark';
  } else {
    delete root.dataset.appearance;
  }
}

type Props = {
  onImportSessions?: () => void;
  onRecountTotals?: () => void;
  importBusy?: boolean;
  recountDisabled?: boolean;
};

export function DeckOverflowMenu({
  onImportSessions,
  onRecountTotals,
  importBusy = false,
  recountDisabled = true
}: Props) {
  const skin = useShellStore((s) => s.skin);
  const toggleSkin = useShellStore((s) => s.toggleSkin);
  const setRoute = useShellStore((s) => s.setRoute);
  const [open, setOpen] = useState(false);
  const [appearance, setAppearance] = useState<AppearanceMode>(() => readAppearanceMode());
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const menuId = useId();

  useEffect(() => {
    applyAppearanceMode(appearance);
    document.documentElement.dataset.skin = skin;
  }, [appearance, skin]);

  useEffect(() => {
    if (!open) return;
    const checked = menuRef.current?.querySelector<HTMLButtonElement>('[aria-checked="true"]');
    const firstEnabled = menuRef.current?.querySelector<HTMLButtonElement>('button:not(:disabled)');
    (checked ?? firstEnabled)?.focus();
    const onDoc = (ev: MouseEvent) => {
      if (!rootRef.current?.contains(ev.target as Node)) setOpen(false);
    };
    const onKey = (ev: KeyboardEvent) => {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        setOpen(false);
        triggerRef.current?.focus();
      }
    };
    document.addEventListener('mousedown', onDoc);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDoc);
      document.removeEventListener('keydown', onKey);
    };
  }, [open]);

  const closeMenu = () => {
    setOpen(false);
    triggerRef.current?.focus();
  };

  const onMenuKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const items = Array.from(
      menuRef.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? []
    );
    if (items.length === 0) return;
    const current = items.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      const delta = event.key === 'ArrowDown' ? 1 : -1;
      items[(current + delta + items.length) % items.length]?.focus();
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      items[event.key === 'Home' ? 0 : items.length - 1]?.focus();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      closeMenu();
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      (document.activeElement as HTMLButtonElement | null)?.click();
    }
  };

  const pickAppearance = (mode: AppearanceMode) => {
    setAppearance(mode);
    applyAppearanceMode(mode);
  };

  const pickSkin = (next: ShellSkin) => {
    if (next !== skin) toggleSkin();
  };

  return (
    <div className="deck-overflow" ref={rootRef}>
      <button
        ref={triggerRef}
        type="button"
        className="deck-overflow-trigger deck-capsule-trigger deck-capsule-trigger--icon"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={menuId}
        aria-label="More actions"
        onClick={() => setOpen((v) => !v)}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            setOpen(true);
          }
        }}
      >
        {importBusy ? (
          <span className="deck-overflow-spin" aria-hidden="true">
            ↻
          </span>
        ) : (
          <span className="deck-overflow-ellipsis" aria-hidden="true">
            ⋯
          </span>
        )}
      </button>
      {open ? (
        <div
          ref={menuRef}
          className="deck-overflow-panel"
          id={menuId}
          role="menu"
          aria-label="More actions"
          onKeyDown={onMenuKeyDown}
        >
          <p className="deck-overflow-section-label">Appearance</p>
          {APPEARANCE_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="menuitemradio"
              aria-checked={appearance === opt.id}
              className="deck-overflow-item"
              onClick={() => pickAppearance(opt.id)}
            >
              <span className="deck-overflow-item-check" aria-hidden="true">
                {appearance === opt.id ? '✓' : ''}
              </span>
              {opt.label}
            </button>
          ))}

          <p className="deck-overflow-section-label">App skin</p>
          {SKIN_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="menuitemradio"
              aria-checked={skin === opt.id}
              className="deck-overflow-item"
              onClick={() => pickSkin(opt.id)}
            >
              <span className="deck-overflow-item-check" aria-hidden="true">
                {skin === opt.id ? '✓' : ''}
              </span>
              {opt.label}
            </button>
          ))}

          <div className="deck-overflow-divider" role="separator" />

          <button
            type="button"
            role="menuitem"
            className="deck-overflow-item"
            disabled={importBusy}
            onClick={() => {
              onImportSessions?.();
              closeMenu();
            }}
          >
            Import sessions
          </button>
          <button
            type="button"
            role="menuitem"
            className="deck-overflow-item"
            disabled={recountDisabled}
            onClick={() => {
              onRecountTotals?.();
              closeMenu();
            }}
          >
            Recount totals
          </button>
          <button
            type="button"
            role="menuitem"
            className="deck-overflow-item"
            onClick={() => {
              setRoute('settings');
              closeMenu();
            }}
          >
            Settings…
          </button>
        </div>
      ) : null}
    </div>
  );
}
