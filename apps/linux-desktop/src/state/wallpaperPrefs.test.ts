// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  applyWallpaperBackground,
  DEFAULT_WALLPAPER,
  isWallpaperBackground,
  persistWallpaperBackground,
  readWallpaperBackground,
  WALLPAPER_OPTIONS,
  WALLPAPER_PREFS_KEY
} from './wallpaperPrefs.js';

describe('wallpaper preference contract', () => {
  beforeEach(() => {
    localStorage.clear();
    delete document.documentElement.dataset.wallpaper;
  });

  afterEach(() => {
    localStorage.clear();
    delete document.documentElement.dataset.wallpaper;
  });

  it('covers all eleven macOS wallpaper backgrounds', () => {
    expect(WALLPAPER_OPTIONS).toHaveLength(11);
    expect(isWallpaperBackground('solarFlare')).toBe(true);
    expect(isWallpaperBackground('not-a-wallpaper')).toBe(false);
    expect(readWallpaperBackground()).toBe(DEFAULT_WALLPAPER);
  });

  it('persists only validated values and applies the root dataset', () => {
    persistWallpaperBackground('auroraTeal');
    expect(localStorage.getItem(WALLPAPER_PREFS_KEY)).toBe('auroraTeal');
    expect(document.documentElement.dataset.wallpaper).toBe('auroraTeal');
    expect(readWallpaperBackground()).toBe('auroraTeal');

    applyWallpaperBackground('not-a-wallpaper' as never);
    expect(document.documentElement.dataset.wallpaper).toBe('auroraTeal');
  });
});
