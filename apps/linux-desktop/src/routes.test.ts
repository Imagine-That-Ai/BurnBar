import { describe, expect, it } from 'vitest';
import { ROUTES, routeFromHash } from './routes.js';

describe('routeFromHash', () => {
  it('defaults to overview', () => {
    expect(routeFromHash('')).toBe('overview');
  });

  it('parses dashboard routes', () => {
    expect(routeFromHash('#/missions')).toBe('missions');
    expect(routeFromHash('#/computer-use')).toBe('computer-use');
    expect(routeFromHash('#/text-expansion')).toBe('text-expansion');
  });

  it('covers all navigation ids', () => {
    const ids = new Set(ROUTES.map((r) => r.id));
    expect(ids.has('chat')).toBe(true);
    expect(ids.has('computer-use')).toBe(true);
    expect(ids.has('support')).toBe(true);
    expect(ids.size).toBeGreaterThanOrEqual(14);
  });
});
