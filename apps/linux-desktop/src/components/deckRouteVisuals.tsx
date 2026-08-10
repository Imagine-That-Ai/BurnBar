import type { ShellRoute } from '../routes.js';
import { PROVIDER_GLYPHS } from '../providerGlyphs.js';

const ROUTE_PROVIDER: Partial<Record<ShellRoute, string>> = {
  overview: 'codex',
  insights: 'anthropic',
  inbox: 'codex',
  database: 'hermes',
  providers: 'openai',
  projects: 'cursor',
  missions: 'opencode',
  activity: 'anthropic',
  chat: 'hermes',
  memory: 'google',
  settings: 'codex',
  account: 'openai'
};

function providerAccent(route: ShellRoute): string {
  const id = ROUTE_PROVIDER[route] ?? 'codex';
  const glyph = PROVIDER_GLYPHS.find((g) => g.id === id) ?? PROVIDER_GLYPHS[0]!;
  return glyph.accent;
}

/** Compact route glyph for the section switcher label (16px slot). */
export function DeckRouteIcon({ route }: { route: ShellRoute }) {
  const accent = providerAccent(route);
  switch (route) {
    case 'inbox':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M2.5 3.2h11l1 5.2v4.1A1.5 1.5 0 0 1 13 14H3a1.5 1.5 0 0 1-1.5-1.5V8.4l1-5.2Zm1.2 1.4-.6 3.1h2.5l.7 1.4h3.4l.7-1.4h2.5l-.6-3.1H3.7Z"
          />
        </svg>
      );
    case 'database':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M2 4.5A3.5 3.5 0 0 1 8 2.5a3.5 3.5 0 0 1 6 2v7a3.5 3.5 0 0 1-6 2 3.5 3.5 0 0 1-6-2v-7Zm6-1.2a2.2 2.2 0 0 0-4.4 0v.4h4.4v-.4Zm0 2.6H3.6v4.1a2.2 2.2 0 0 0 4.4 0V5.9Zm2 0v4.1a2.2 2.2 0 0 0 4.4 0V5.9h-4.4Z"
          />
        </svg>
      );
    case 'projects':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path fill="currentColor" d="M2 3.5A1.5 1.5 0 0 1 3.5 2h3l1 1H12.5A1.5 1.5 0 0 1 14 4.5v8A1.5 1.5 0 0 1 12.5 14h-9A1.5 1.5 0 0 1 2 12.5v-9Z" />
        </svg>
      );
    case 'missions':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path fill="currentColor" d="M3 2.5 8 1l5 1.5v5.2c0 2.8-1.8 4.5-5 5.8-3.2-1.3-5-3-5-5.8V2.5Zm5 .9-3.2 1 3.2 1 3.2-1L8 3.4Z" />
        </svg>
      );
    case 'activity':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M3 3.5A1.5 1.5 0 0 1 4.5 2h7A1.5 1.5 0 0 1 13 3.5v5.8l-2.2 1.4-2.3-2.8-2.5 3.1-2-1.6V3.5Z"
          />
        </svg>
      );
    case 'memory':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M8 2.2c2.2 0 4 1.2 4.8 3.1.9-.3 1.8-.1 2.5.5.9.8 1.1 2.1.4 3.1-.5.7-1.3 1.1-2.2 1.1-.3 1.9-1.9 3.4-3.9 3.8-.4 1.1-1.4 1.9-2.6 1.9-1.5 0-2.7-1.2-2.7-2.7 0-.4.1-.8.3-1.1C3.4 11.2 2 9.4 2 7.2c0-2.8 2.7-5 6-5Z"
          />
        </svg>
      );
    case 'chat':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M3 3.5A1.5 1.5 0 0 1 4.5 2h7A1.5 1.5 0 0 1 13 3.5v5A1.5 1.5 0 0 1 11.5 10H7l-3 2.5V3.5Z"
          />
        </svg>
      );
    case 'providers':
      return (
        <svg className="deck-route-icon" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true">
          <path
            fill="currentColor"
            d="M4 4.5h8v1.8H9.2v4.2H6.8V6.3H4V4.5Zm1.2 7.5h5.6v1.8H5.2v-1.8Z"
          />
        </svg>
      );
    default:
      return (
        <span className="deck-route-icon-fallback" style={{ color: accent }} aria-hidden="true">
          •
        </span>
      );
  }
}
