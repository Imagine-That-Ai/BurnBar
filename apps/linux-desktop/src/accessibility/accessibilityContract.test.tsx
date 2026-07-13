// @vitest-environment jsdom
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { cleanup, render } from '@testing-library/react';
import { afterEach, describe, expect, it } from 'vitest';
import { GlassAlert } from '../components/GlassAlert.js';
import { StatusPill } from '../components/StatusPill.js';

const stylesDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../styles');
const appCss = fs.readFileSync(path.join(stylesDir, 'app.css'), 'utf8');

function mediaBlock(query: string): string {
  const start = appCss.indexOf(`@media (${query})`);
  if (start < 0) return '';
  const open = appCss.indexOf('{', start);
  if (open < 0) return '';

  let depth = 0;
  for (let index = open; index < appCss.length; index += 1) {
    if (appCss[index] === '{') depth += 1;
    if (appCss[index] === '}') {
      depth -= 1;
      if (depth === 0) return appCss.slice(start, index + 1);
    }
  }
  return '';
}

describe('Linux accessibility preference contracts', () => {
  afterEach(cleanup);

  it('keeps global reduced-motion, high-contrast, and forced-colors rules in the shell stylesheet', () => {
    const reducedMotion = mediaBlock('prefers-reduced-motion: reduce');
    const highContrast = mediaBlock('prefers-contrast: more');
    const forcedColors = mediaBlock('forced-colors: active');

    expect(reducedMotion).toContain('animation: none !important');
    expect(reducedMotion).toContain('transition: none !important');
    expect(reducedMotion).toContain('scroll-behavior: auto !important');

    expect(highContrast).toContain('--a11y-border-strong');
    expect(highContrast).toContain(':focus-visible');
    expect(highContrast).toMatch(/\[role=['"]status['"]\]/);
    expect(highContrast).toMatch(/\[role=['"]alert['"]\]/);

    expect(forcedColors).toContain('ButtonFace');
    expect(forcedColors).toContain('ButtonText');
    expect(forcedColors).toContain('Highlight');
    expect(forcedColors).toContain(':focus-visible');
    expect(forcedColors).toMatch(/\[role=['"]status['"]\]/);
    expect(forcedColors).toMatch(/\[role=['"]alert['"]\]/);
  });

  it('retains keyboard controls and live status semantics under the shared shell contract', () => {
    const { container } = render(
      <>
        <button type="button" aria-label="Retry daemon connection">
          Retry
        </button>
        <StatusPill
          status={{
            label: 'Daemon ready',
            detail: 'Connected over AF_UNIX.',
            tone: 'ok',
            ok: true
          }}
        />
        <GlassAlert role="alert">The daemon is unavailable.</GlassAlert>
      </>
    );

    const control = container.querySelector('button[aria-label="Retry daemon connection"]');
    expect(control).not.toBeNull();
    expect(control?.getAttribute('type')).toBe('button');
    expect(control?.getAttribute('tabindex')).not.toBe('-1');
    expect(container.querySelector('.status-pill[role="status"]')).not.toBeNull();
    expect(container.querySelector('.glass-alert[role="alert"]')).not.toBeNull();
  });
});
