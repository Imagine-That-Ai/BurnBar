import { useEffect, useState } from 'react';
import { useShellStore, type ShellSkin } from '../../state/shellStore.js';

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
    const raw = localStorage.getItem(APPEARANCE_KEY);
    if (raw === 'light' || raw === 'dark' || raw === 'system') return raw;
  } catch {
    /* ignore */
  }
  return 'system';
}

function applyAppearanceMode(mode: AppearanceMode): void {
  try {
    localStorage.setItem(APPEARANCE_KEY, mode);
  } catch {
    /* convenience only */
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

export function SettingsAppearanceControls() {
  const skin = useShellStore((s) => s.skin);
  const toggleSkin = useShellStore((s) => s.toggleSkin);
  const [appearance, setAppearance] = useState<AppearanceMode>(() => readAppearanceMode());

  useEffect(() => {
    applyAppearanceMode(appearance);
    document.documentElement.dataset.skin = skin;
  }, [appearance, skin]);

  return (
    <div className="settings-appearance-controls">
      <fieldset className="settings-appearance-fieldset">
        <legend className="settings-appearance-legend">Color scheme</legend>
        <div className="settings-appearance-options" role="radiogroup" aria-label="Color scheme">
          {APPEARANCE_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={appearance === opt.id}
              className={`settings-appearance-option${appearance === opt.id ? ' settings-appearance-option--on' : ''}`}
              onClick={() => {
                setAppearance(opt.id);
                applyAppearanceMode(opt.id);
              }}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </fieldset>
      <fieldset className="settings-appearance-fieldset">
        <legend className="settings-appearance-legend">App skin</legend>
        <div className="settings-appearance-options" role="radiogroup" aria-label="App skin">
          {SKIN_OPTIONS.map((opt) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={skin === opt.id}
              className={`settings-appearance-option${skin === opt.id ? ' settings-appearance-option--on' : ''}`}
              onClick={() => {
                if (skin !== opt.id) toggleSkin();
              }}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </fieldset>
      <p className="muted settings-tab-lede">
        Backdrop kernel selection stays on the Overview deck until appearance prefs sync across the Linux bridge.
      </p>
    </div>
  );
}