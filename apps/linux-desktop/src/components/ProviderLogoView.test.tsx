// @vitest-environment jsdom
import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import { ProviderLogoView, providerFallbackGlyph } from './ProviderLogoView.js';

describe('ProviderLogoView fallback glyphs', () => {
  it('uses a deterministic monochrome glyph when a provider asset is absent', () => {
    render(<ProviderLogoView id="unknown-provider" size={24} />);
    const fallback = screen.getByText('UP');

    expect((fallback as HTMLElement).style.fontFamily).toBe('var(--font-mono)');
    expect(fallback.getAttribute('aria-hidden')).toBe('true');
  });

  it('does not use emoji-only fallback glyphs for known providers', () => {
    const providers = [
      'openai', 'anthropic', 'claude-code', 'cursor', 'codex', 'copilot', 'google', 'gemini',
      'ollama', 'hermes', 'opencode', 'deepseek', 'grok', 'factory', 'minimax', 'kimi', 'cline',
      'kilocode', 'roocode', 'openclaw', 'openburnbar', 'windsurf', 'goose', 'antigravity', 'piagent'
    ];
    const { container } = render(
      <>
        {providers.map((id) => <ProviderLogoView key={id} id={id} size={24} />)}
      </>
    );

    expect(container.textContent).not.toMatch(/[\u{1F300}-\u{1FAFF}]/u);
  });

  it('keeps catalog-only providers visually distinct with stable monograms', () => {
    expect(providerFallbackGlyph('zai')).toBe('ZA');
    expect(providerFallbackGlyph('cursor-agent')).toBe('CU');
    expect(providerFallbackGlyph('JetBrains Junie')).toBe('JJ');
    expect(providerFallbackGlyph('')).toBe('?');
  });
});
