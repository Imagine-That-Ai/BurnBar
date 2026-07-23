import { useEffect, useRef, useState, type KeyboardEvent, type MutableRefObject } from 'react';
import { useShellStore, type ShellSkin } from '../../state/shellStore.js';

type AppearanceMode = 'system' | 'light' | 'dark';
type GlassTransparency = number;

const APPEARANCE_KEY = 'openburnbar.linux.appearanceMode.v1';
const GLASS_TRANSPARENCY_KEY = 'openburnbar.linux.glassTransparency.v1';

const APPEARANCE_OPTIONS: { id: AppearanceMode; label: string }[] = [
  { id: 'system', label: 'Match system' },
  { id: 'light', label: 'Light' },
  { id: 'dark', label: 'Dark' }
];

const SKIN_OPTIONS: { id: ShellSkin; label: string }[] = [
  { id: 'editorial', label: 'Editorial' },
  { id: 'aurora', label: 'Aurora' }
];

const GLASS_TRANSPARENCY_MIN = -1;
const GLASS_TRANSPARENCY_MAX = 1;

type RadioOption = { id: string; label: string };

function handleRadioKeyDown(
  event: KeyboardEvent<HTMLButtonElement>,
  currentIndex: number,
  options: readonly RadioOption[],
  setValue: (id: string) => void,
  buttonRefs: MutableRefObject<Record<string, HTMLButtonElement | null>>
): void {
  let nextIndex: number | null = null;
  switch (event.key) {
    case 'ArrowRight':
    case 'ArrowDown':
      nextIndex = (currentIndex + 1) % options.length;
      break;
    case 'ArrowLeft':
    case 'ArrowUp':
      nextIndex = (currentIndex - 1 + options.length) % options.length;
      break;
    case 'Home':
      nextIndex = 0;
      break;
    case 'End':
      nextIndex = options.length - 1;
      break;
    default:
      return;
  }

  event.preventDefault();
  const next = options[nextIndex];
  if (!next) return;
  setValue(next.id);
  buttonRefs.current[next.id]?.focus();
}

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

function readGlassTransparency(): GlassTransparency {
  try {
    const raw = Number(localStorage.getItem(GLASS_TRANSPARENCY_KEY));
    if (Number.isFinite(raw)) return clampGlassTransparency(raw);
  } catch {
    /* ignore */
  }
  return 0;
}

function clampGlassTransparency(value: number): GlassTransparency {
  return Math.min(GLASS_TRANSPARENCY_MAX, Math.max(GLASS_TRANSPARENCY_MIN, value));
}

function glassTransparencyTone(value: GlassTransparency): 'frostier' | 'balanced' | 'clearer' {
  if (value < -0.005) return 'frostier';
  if (value > 0.005) return 'clearer';
  return 'balanced';
}

function glassTransparencyDescription(value: GlassTransparency): string {
  const percent = Math.round(Math.abs(value) * 100);
  if (percent === 0) return 'System default';
  return `${percent}% ${value < 0 ? 'frostier' : 'clearer'} than system`;
}

function applyGlassTransparency(value: GlassTransparency): void {
  const normalized = clampGlassTransparency(value);
  try {
    localStorage.setItem(GLASS_TRANSPARENCY_KEY, String(normalized));
  } catch {
    /* convenience only */
  }
  const root = document.documentElement;
  root.dataset.glassTransparency = glassTransparencyTone(normalized);
  root.style.setProperty('--glass-tint-base-opacity', `${48 - normalized * 16}%`);
  root.style.setProperty('--glass-tint-elevated-opacity', `${55 - normalized * 17}%`);
  root.style.setProperty('--glass-tint-clear-opacity', `${28 - normalized * 14}%`);
  root.style.setProperty('--glass-tint-interactive-opacity', `${38 - normalized * 16}%`);
  root.style.setProperty('--glass-input-opacity', `${55 - normalized * 13}%`);
}

export function SettingsAppearanceControls() {
  const skin = useShellStore((s) => s.skin);
  const toggleSkin = useShellStore((s) => s.toggleSkin);
  const [appearance, setAppearance] = useState<AppearanceMode>(() => readAppearanceMode());
  const [glassTransparency, setGlassTransparency] = useState<GlassTransparency>(() => readGlassTransparency());
  const appearanceButtonRefs = useRef<Record<string, HTMLButtonElement | null>>({});
  const skinButtonRefs = useRef<Record<string, HTMLButtonElement | null>>({});

  useEffect(() => {
    applyAppearanceMode(appearance);
    applyGlassTransparency(glassTransparency);
    document.documentElement.dataset.skin = skin;
  }, [appearance, glassTransparency, skin]);

  return (
    <div className="settings-appearance-controls">
      <fieldset className="settings-appearance-fieldset">
        <legend className="settings-appearance-legend">Color scheme</legend>
        <div className="settings-appearance-options" role="radiogroup" aria-label="Color scheme" aria-orientation="horizontal">
          {APPEARANCE_OPTIONS.map((opt, index) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={appearance === opt.id}
              tabIndex={appearance === opt.id ? 0 : -1}
              ref={(element) => {
                appearanceButtonRefs.current[opt.id] = element;
              }}
              className={`settings-appearance-option${appearance === opt.id ? ' settings-appearance-option--on' : ''}`}
              onKeyDown={(event) => handleRadioKeyDown(event, index, APPEARANCE_OPTIONS, (id) => {
                const next = id as AppearanceMode;
                setAppearance(next);
                applyAppearanceMode(next);
              }, appearanceButtonRefs)}
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
        <div className="settings-appearance-options" role="radiogroup" aria-label="App skin" aria-orientation="horizontal">
          {SKIN_OPTIONS.map((opt, index) => (
            <button
              key={opt.id}
              type="button"
              role="radio"
              aria-checked={skin === opt.id}
              tabIndex={skin === opt.id ? 0 : -1}
              ref={(element) => {
                skinButtonRefs.current[opt.id] = element;
              }}
              className={`settings-appearance-option${skin === opt.id ? ' settings-appearance-option--on' : ''}`}
              onKeyDown={(event) => handleRadioKeyDown(event, index, SKIN_OPTIONS, (id) => {
                if (skin !== id) toggleSkin();
              }, skinButtonRefs)}
              onClick={() => {
                if (skin !== opt.id) toggleSkin();
              }}
            >
              {opt.label}
            </button>
          ))}
        </div>
      </fieldset>
      <fieldset className="settings-appearance-fieldset settings-appearance-transparency">
        <legend className="settings-appearance-legend">Liquid Glass</legend>
        <label className="settings-appearance-range-label" htmlFor="glass-transparency-range">
          <span>Transparency</span>
          <output aria-live="polite" htmlFor="glass-transparency-range">
            {glassTransparencyDescription(glassTransparency)}
          </output>
        </label>
        <input
          id="glass-transparency-range"
          className="settings-appearance-range"
          type="range"
          min="-1"
          max="1"
          step="0.01"
          value={glassTransparency}
          aria-label="Liquid Glass transparency"
          aria-valuetext={glassTransparencyDescription(glassTransparency)}
          onChange={(event) => {
            const next = Number(event.target.value);
            if (!Number.isFinite(next)) return;
            const value = clampGlassTransparency(next);
            setGlassTransparency(value);
            applyGlassTransparency(value);
          }}
        />
        <div className="settings-appearance-range-scale" aria-hidden="true">
          <span>Frostier</span>
          <span>Clearer</span>
        </div>
      </fieldset>
      <p className="muted settings-tab-lede">
        Backdrop kernel selection stays on the Overview deck until appearance prefs sync across the Linux bridge.
      </p>
    </div>
  );
}
