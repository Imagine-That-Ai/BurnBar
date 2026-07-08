import { describe, expect, it } from 'vitest';
import { ROUTES, routeFromHash } from './routes.js';

describe('routeFromHash', () => {
  it('defaults to overview', () => {
    expect(routeFromHash('')).toBe('overview');
  });

  it('parses dashboard routes', () => {
    expect(routeFromHash('#/missions')).toBe('missions');
    expect(routeFromHash('#/text-expansion')).toBe('text-expansion');
  });

  it('covers all navigation ids', () => {
    expect(ROUTES.map((r) => r.id)).toEqual([
      'overview',
      'insights',
      'database',
      'providers',
      'projects',
      'missions',
      'activity',
      'chat',
      'memory',
      'settings',
      'account',
      'updates',
      'support',
      'onboarding',
      'pet',
      'text-expansion'
    ]);
  });

  it('preserves route state through reload-safe hashes', () => {
    for (const route of ROUTES) {
      expect(routeFromHash(`app://openburnbar-linux/#/${route.id}`)).toBe(route.id);
    }
  });
});
