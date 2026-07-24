// @vitest-environment jsdom
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { GlassButton } from './GlassButton.js';
import { GlassCard } from './GlassCard.js';

describe('macOS glass primitives', () => {
  it('renders GlassCard with semantic element and interactive modifiers', () => {
    render(
      <GlassCard as="section" interactive embedded aria-label="Card">
        Card content
      </GlassCard>
    );
    const card = screen.getByRole('region', { name: 'Card' });
    expect(card.className).toContain('card');
    expect(card.className).toContain('glass-card');
    expect(card.className).toContain('glass-card--interactive');
    expect(card.className).toContain('glass-card--embedded');
  });

  it('renders GlassButton with the requested variant and button type', () => {
    render(<GlassButton variant="prominent">Run</GlassButton>);
    const button = screen.getByRole('button', { name: 'Run' });
    expect(button.className).toContain('glass-button');
    expect(button.className).toContain('glass-button--prominent');
    expect(button.getAttribute('type')).toBe('button');
  });
});
