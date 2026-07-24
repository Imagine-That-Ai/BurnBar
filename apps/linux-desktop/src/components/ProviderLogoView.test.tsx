// @vitest-environment jsdom
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { ProviderLogoView } from './ProviderLogoView.js';

describe('ProviderLogoView fallback glyphs', () => {
  it('uses a deterministic monochrome glyph when a provider asset is absent', () => {
    render(<ProviderLogoView id="unknown-provider" size={24} />);
    const fallback = screen.getByText('✦');

    expect((fallback as HTMLElement).style.fontFamily).toBe('var(--font-mono)');
    expect(fallback).toHaveAttribute('aria-hidden', 'true');
  });

  it('does not use emoji-only fallback glyphs for known providers', () => {
    const providers = ['claude-code', 'codex', 'deepseek', 'factory', 'goose', 'kimi', 'roocode', 'windsurf'];
    const { container } = render(
      <>
        {providers.map((id) => <ProviderLogoView key={id} id={id} size={24} />)}
      </>
    );

    expect(container.textContent).not.toMatch(/[\u{1F300}-\u{1FAFF}]/u);
  });
});
