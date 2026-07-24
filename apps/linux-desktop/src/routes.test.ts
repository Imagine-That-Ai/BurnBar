import { describe, expect, it } from 'vitest';
import {
  providerRouteHash,
  providerSelectionFromHash,
  ROUTES,
  routeFromHash,
  shellDestinationFromNative
} from './routes.js';

describe('routeFromHash', () => {
  it('defaults to overview', () => {
    expect(routeFromHash('')).toBe('overview');
  });

  it('parses dashboard routes', () => {
    expect(routeFromHash('#/missions')).toBe('missions');
    expect(routeFromHash('#/text-expansion')).toBe('text-expansion');
    expect(routeFromHash('#/providers?provider=codex&model=gpt-5')).toBe('providers');
  });

  it('round-trips bounded provider and model detail', () => {
    const hash = providerRouteHash('openai/team', 'gpt-5.2 codex');
    expect(hash).toBe('#/providers?provider=openai%2Fteam&model=gpt-5.2+codex');
    expect(providerSelectionFromHash(hash)).toEqual({
      providerID: 'openai/team',
      modelID: 'gpt-5.2 codex'
    });
  });

  it('rejects provider detail outside the providers route or size bound', () => {
    expect(providerSelectionFromHash('#/settings?provider=codex')).toBeNull();
    expect(providerSelectionFromHash('#/providers?model=gpt-5')).toBeNull();
    expect(providerSelectionFromHash(`#/providers?provider=${'a'.repeat(257)}`)).toBeNull();
  });

  it('validates native top-level and provider-detail destinations', () => {
    expect(shellDestinationFromNative('chat')).toEqual({ route: 'chat', hash: '#/chat' });
    expect(shellDestinationFromNative('providers?provider=openai&model=gpt-5')).toEqual({
      route: 'providers',
      hash: '#/providers?provider=openai&model=gpt-5'
    });
    expect(shellDestinationFromNative('chat?prompt=secret')).toBeNull();
    expect(shellDestinationFromNative('unknown')).toBeNull();
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
      'computer-use',
      'mercury',
      'smarthub',
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
