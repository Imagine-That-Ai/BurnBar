/** Desktop backdrop palette mirrored from macOS DesktopWallpaperBackground. */
export const WALLPAPER_PREFS_KEY = 'openburnbar.linux.wallpaper.v1';

export const WALLPAPER_OPTIONS = [
  { id: 'macosDesktop', label: 'BurnBar Desktop', detail: 'BurnBar-owned blue, ember, and amber stage.' },
  { id: 'midnight', label: 'Midnight', detail: 'Near-black with a quiet blue cast.' },
  { id: 'amoledBlack', label: 'AMOLED Black', detail: 'Pitch black for OLED and maximum particle contrast.' },
  { id: 'graphite', label: 'Graphite', detail: 'Neutral dark gray with restrained contrast.' },
  { id: 'warmEmber', label: 'Warm Ember', detail: 'Dark warm brown tuned for BurnBar embers.' },
  { id: 'deepIndigo', label: 'Deep Indigo', detail: 'Deep violet-blue stage for provider colors.' },
  { id: 'auroraTeal', label: 'Aurora Teal', detail: 'Deep teal inspired by northern lights.' },
  { id: 'sunsetCrimson', label: 'Sunset Crimson', detail: 'Dark velvet burgundy-red sunset mood.' },
  { id: 'cyberpunkViolet', label: 'Cyberpunk Violet', detail: 'Dark indigo-magenta cybernetic backdrop.' },
  { id: 'forestMoss', label: 'Forest Moss', detail: 'Quiet dark pine green with foggy depth.' },
  { id: 'solarFlare', label: 'Solar Flare', detail: 'Dark solar corona with golden accents.' }
] as const;

export type WallpaperBackground = (typeof WALLPAPER_OPTIONS)[number]['id'];
export const DEFAULT_WALLPAPER: WallpaperBackground = 'macosDesktop';

export function isWallpaperBackground(value: unknown): value is WallpaperBackground {
  return typeof value === 'string' && WALLPAPER_OPTIONS.some((option) => option.id === value);
}

export function readWallpaperBackground(): WallpaperBackground {
  try {
    const raw = localStorage.getItem(WALLPAPER_PREFS_KEY);
    return isWallpaperBackground(raw) ? raw : DEFAULT_WALLPAPER;
  } catch {
    return DEFAULT_WALLPAPER;
  }
}

export function applyWallpaperBackground(
  value: WallpaperBackground,
  root: Pick<HTMLElement, 'dataset'> | null =
    typeof document !== 'undefined' ? document.documentElement : null
): void {
  if (!root || !isWallpaperBackground(value)) return;
  root.dataset.wallpaper = value;
}

export function persistWallpaperBackground(value: WallpaperBackground): void {
  if (!isWallpaperBackground(value)) return;
  try {
    localStorage.setItem(WALLPAPER_PREFS_KEY, value);
  } catch {
    // Convenience preference; the live dataset still updates.
  }
  applyWallpaperBackground(value);
}
