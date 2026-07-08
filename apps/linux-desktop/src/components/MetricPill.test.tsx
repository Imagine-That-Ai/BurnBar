// @vitest-environment jsdom
import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { MetricPill } from './MetricPill.js';

describe('MetricPill', () => {
  afterEach(cleanup);

  it('exposes accessible label as label, value', () => {
    render(<MetricPill label="tokens" value={12840} tint="var(--color-brass-core)" icon="◎" />);
    expect(screen.getByRole('status', { name: 'tokens, 12840' })).toBeTruthy();
    expect(screen.getByText('tokens')).toBeTruthy();
    expect(screen.getByText('12840')).toBeTruthy();
  });

  it('applies tint via CSS variable on the pill', () => {
    const { container } = render(<MetricPill label="cache hit" value="92%" tint="var(--color-tier-end-to-end)" />);
    const pill = container.querySelector('.metric-pill') as HTMLElement;
    expect(pill.style.getPropertyValue('--metric-pill-tint')).toBe('var(--color-tier-end-to-end)');
  });
});