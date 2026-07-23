import { describe, expect, it } from 'vitest';
import {
  decodeDesktopWallpaperStatus,
  defaultNotificationConfig,
  mapNotificationConfig
} from './tauriBridgePlatformDecoders.js';

describe('notification settings decoder', () => {
  it('keeps the complete default contract when an older daemon omits fields', () => {
    expect(mapNotificationConfig({})).toEqual(defaultNotificationConfig());
  });

  it('normalizes invalid settings instead of surfacing unsafe or unusable values', () => {
    const decoded = mapNotificationConfig({
      defaultSnoozeMinutes: -10,
      nudgeHoursLocal: [-1, 9.8, 9, 24, '17', 'not-a-hour'],
      local: { isEnabled: false, quietHoursStart: 25, quietHoursEnd: 6.9 },
      telegram: { isEnabled: true, supportedCommands: [] },
      calendar: { isEnabled: true, defaultDurationMinutes: 7 }
    });

    expect(decoded.defaultSnoozeMinutes).toBe(30);
    expect(decoded.nudgeHoursLocal).toEqual([9, 17]);
    expect(decoded.local).toEqual({ isEnabled: false, quietHoursStart: null, quietHoursEnd: null });
    expect(decoded.telegram.isEnabled).toBe(true);
    expect(decoded.telegram.supportedCommands).toEqual(defaultNotificationConfig().telegram.supportedCommands);
    expect(decoded.calendar).toMatchObject({ isEnabled: true, defaultDurationMinutes: 30 });
  });

  it('preserves valid values while de-duplicating repeated nudge hours', () => {
    const decoded = mapNotificationConfig({
      defaultSnoozeMinutes: 1440,
      nudgeHoursLocal: [17, 9, 17, 13],
      local: { isEnabled: true, quietHoursStart: 22, quietHoursEnd: 7 },
      telegram: { isEnabled: false, supportedCommands: ['status'] },
      calendar: { isEnabled: true, defaultDurationMinutes: 60, defaultCalendarName: 'Work' }
    });

    expect(decoded.defaultSnoozeMinutes).toBe(1440);
    expect(decoded.nudgeHoursLocal).toEqual([17, 9, 13]);
    expect(decoded.local).toEqual({ isEnabled: true, quietHoursStart: 22, quietHoursEnd: 7 });
    expect(decoded.telegram.supportedCommands).toEqual(['status']);
    expect(decoded.calendar).toMatchObject({ isEnabled: true, defaultDurationMinutes: 60, defaultCalendarName: 'Work' });
  });
});

describe('desktop wallpaper decoder', () => {
  it('accepts the bounded native backend and state vocabulary', () => {
    expect(decodeDesktopWallpaperStatus({
      available: true,
      backend: 'gnome',
      state: 'applied',
      theme: 'auroraTeal',
      path: '/home/test/.local/share/openburnbar/wallpapers/auroraTeal.svg'
    })).toMatchObject({ backend: 'gnome', state: 'applied', theme: 'auroraTeal' });
    expect(decodeDesktopWallpaperStatus({
      available: true,
      backend: 'sway',
      state: 'ready'
    })).toMatchObject({ backend: 'sway', state: 'ready' });
    expect(decodeDesktopWallpaperStatus({
      available: true,
      backend: 'hyprland',
      state: 'applied'
    })).toMatchObject({ backend: 'hyprland', state: 'applied' });
    expect(() => decodeDesktopWallpaperStatus({
      available: true,
      backend: 'cosmic',
      state: 'ready'
    })).toThrow('desktop wallpaper backend is unsupported');
  });
});
