import { useMemo } from 'react';
import { findProviderGlyph } from '../providerGlyphs.js';
import './provider-logo-view.css';

/**
 * ProviderLogoView — faithful port of macOS ProviderLogoView.swift.
 *
 * Renders a provider's bundled logo image with:
 *  - Light mode: provider primary backdrop; dark mode: white (macOS logoBackdrop)
 *  - Rounded-rect clipping (cornerRadius = size * 0.2237)
 *  - SF Symbol fallback → text glyph fallback for providers without a logo asset
 *
 * Logo assets live at /provider-logos/{id}.png (or .svg for some providers).
 */

// Providers that need a white backdrop behind their logo in dark mode
// (matches macOS needsMonochromeLogoBackdrop)
const NEEDS_BACKDROP = new Set([
  'anthropic',
  'claude-code',
  'codex',
  'copilot',
  'cursor',
  'openai',
  'ollama',
  'gemini',
  'google',
  'deepseek',
  'grok',
  'kimi',
  'minimax',
  'factory',
  'opencode',
  'windsurf',
  'cline',
  'kilocode',
  'roocode',
  'goose',
  'openclaw',
  'antigravity',
]);

// Fallback text glyphs for providers without logo assets. Keep these
// monochrome and font-stable: emoji presentation varies by distro and can
// change the visual weight of dense provider lists.
const FALLBACK_GLYPH: Record<string, string> = {
  openai: '✦',
  anthropic: '✦',
  'claude-code': '◌',
  cursor: '◎',
  codex: '⌘',
  copilot: '✦',
  google: '◆',
  gemini: '◆',
  ollama: '▦',
  hermes: '≋',
  opencode: '</>',
  deepseek: '◈',
  grok: 'ϟ',
  factory: '▣',
  minimax: '★',
  kimi: '☾',
  cline: '◈',
  kilocode: 'K',
  roocode: '◌',
  openclaw: '✦',
  openburnbar: '✦',
  windsurf: '≈',
  goose: '✣',
  antigravity: '✦',
  piagent: '⬡',
};

export type ProviderLogoProps = {
  /** Provider ID — matches PROVIDER_GLYPHS ids and /provider-logos/{id}.png filenames */
  id: string;
  /** Render size in CSS pixels (matches macOS `size` parameter) */
  size?: number;
  /** Whether to show the fallback color (accent) — matches `useFallbackColor` */
  useFallbackColor?: boolean;
  /** Accent color for fallback glyph (from providerGlyphs.ts accent field) */
  accent?: string;
  /** Additional className */
  className?: string;
};

/**
 * Get the logo URL for a provider ID.
 * Returns null if no logo asset is expected to exist.
 */
function logoUrl(id: string): string | null {
  return findProviderGlyph(id).logo || null;
}

export function ProviderLogoView({
  id,
  size = 24,
  useFallbackColor = true,
  accent = '#fa6b06',
  className
}: ProviderLogoProps) {
  const url = useMemo(() => logoUrl(id), [id]);
  const needsBackdrop = NEEDS_BACKDROP.has(id);
  const radius = size * 0.2237;
  const glyph = FALLBACK_GLYPH[id] ?? '✦';

  const containerStyle: React.CSSProperties = {
    width: size,
    height: size,
    borderRadius: radius,
    position: 'relative',
    overflow: 'hidden',
    flexShrink: 0,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  };

  const backdropStyle: React.CSSProperties | undefined = needsBackdrop
    ? ({
        borderRadius: radius,
        '--provider-logo-accent': accent
      } as React.CSSProperties)
    : undefined;

  const imgStyle: React.CSSProperties = {
    width: needsBackdrop ? size * 0.72 : size,
    height: needsBackdrop ? size * 0.72 : size,
    objectFit: 'contain',
    position: 'relative',
    zIndex: 1,
  };

  const glyphStyle: React.CSSProperties = {
    fontSize: size * 0.55,
    fontWeight: 600,
    fontFamily: 'var(--font-mono)',
    color: useFallbackColor ? accent : 'currentColor',
    lineHeight: 1,
  };

  return (
    <div className={`provider-logo-view ${className ?? ''}`} style={containerStyle}>
      {needsBackdrop ? (
        <div className="provider-logo-backdrop" style={backdropStyle} aria-hidden="true" />
      ) : null}
      {url ? (
        <img
          src={url}
          alt=""
          style={imgStyle}
          loading="lazy"
          onError={(e) => {
            // On image load failure, hide img and show fallback glyph
            (e.currentTarget as HTMLImageElement).style.display = 'none';
            const fallback = (e.currentTarget.nextElementSibling as HTMLElement);
            if (fallback) fallback.style.display = 'flex';
          }}
        />
      ) : null}
      {/* Fallback glyph — hidden by default, shown if img fails or no url */}
      <span
        style={{ ...glyphStyle, display: url ? 'none' : 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 1 }}
        aria-hidden="true"
      >
        {glyph}
      </span>
    </div>
  );
}
