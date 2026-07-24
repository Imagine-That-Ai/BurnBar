// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { fixtureUsageSummary } from '../daemonFixture.js';
import { DeckBurnHero } from './DeckBurnHero.js';

describe('DeckBurnHero', () => {
  afterEach(cleanup);

  it('keeps the loading control focusable and stable while telemetry hydrates', () => {
    const { container, rerender } = render(<DeckBurnHero summary={null} loading />);
    const loadingButton = screen.getByRole('button', { name: 'Loading telemetry' });

    expect(loadingButton.getAttribute('aria-busy')).toBe('true');
    expect(loadingButton.getAttribute('aria-disabled')).toBe('true');
    fireEvent.click(loadingButton);
    expect(screen.queryByRole('dialog')).toBeNull();

    rerender(<DeckBurnHero summary={fixtureUsageSummary()} loading={false} />);

    expect(container.querySelector('button')).toBe(loadingButton);
    expect(screen.getByRole('button', { name: /BURN .+ Open range and unit controls/i })).toBe(loadingButton);
    expect(loadingButton.getAttribute('aria-busy')).toBeNull();
    expect(loadingButton.getAttribute('aria-disabled')).toBeNull();
  });
});
