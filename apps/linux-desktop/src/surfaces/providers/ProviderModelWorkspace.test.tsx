// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { fixtureProviderCatalog } from '../../daemonFixture.js';
import type { ProviderCatalog } from '../../tauriBridge.js';
import { ProviderModelWorkspace } from './ProviderModelWorkspace.js';

afterEach(cleanup);

function catalog(): ProviderCatalog {
  return fixtureProviderCatalog();
}

describe('ProviderModelWorkspace', () => {
  it('renders daemon model entries with capability, provenance, health, and failover state', () => {
    render(<ProviderModelWorkspace providers={catalog()} loading={false} onRefresh={vi.fn()} />);

    expect(screen.getByRole('heading', { name: 'Providers & models' })).toBeTruthy();
    expect(screen.getByText('Claude Opus 4.8')).toBeTruthy();
    expect(screen.getAllByText('reasoning').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Healthy').length).toBeGreaterThan(0);
    expect(screen.getAllByText('Eligible').length).toBeGreaterThan(0);
    expect(screen.getAllByText(/fixture/).length).toBeGreaterThan(0);
    expect(screen.getAllByText(/provider-family failover/i).length).toBeGreaterThan(0);
  });

  it('keeps refresh actionable and exposes unavailable catalog provenance', () => {
    const onRefresh = vi.fn();
    const unavailable = catalog().map((provider) => ({
      ...provider,
      catalogAvailable: false,
      catalogError: 'The daemon model catalog is unavailable; retry to refresh.'
    }));
    render(<ProviderModelWorkspace providers={unavailable} loading={false} onRefresh={onRefresh} />);

    expect(screen.getByRole('alert').textContent).toMatch(/model catalog needs a refresh/i);
    const retry = screen.getByRole('button', { name: 'Retry catalog' });
    fireEvent.click(retry);
    expect(onRefresh).toHaveBeenCalledTimes(1);
  });

  it('does not leak provider credentials into model workspace text', () => {
    const secret = 'sk-provider-secret-should-never-render';
    const rows = catalog().map((provider) => ({
      ...provider,
      apiKey: secret
    }));
    render(<ProviderModelWorkspace providers={rows} loading={false} onRefresh={vi.fn()} />);

    expect(screen.queryByText(secret)).toBeNull();
    expect(document.body.textContent).not.toContain(secret);
  });
});
