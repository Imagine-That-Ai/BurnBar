import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const stylesDir = path.dirname(fileURLToPath(import.meta.url));
const appCss = fs.readFileSync(path.join(stylesDir, 'app.css'), 'utf8');
const tokensCss = fs.readFileSync(path.join(stylesDir, 'tokens.css'), 'utf8');
const liquidGlassTokensCss = fs.readFileSync(path.join(stylesDir, 'liquid-glass-tokens.css'), 'utf8');
const skinsCss = fs.readFileSync(path.join(stylesDir, 'skins.css'), 'utf8');
const packageJson = JSON.parse(
  fs.readFileSync(path.join(stylesDir, '../../package.json'), 'utf8')
) as { dependencies?: Record<string, string> };

const HEX = /#[0-9a-fA-F]{3,8}\b/g;
/** Aurora / brand hex that must not reappear outside generated tokens. */
const BANNED_BRAND_HEX = [/#6ee7ff/i, /#8b5cf6/i, /#3cd6c0/i, /#040610/i, /#fa6b06/i];

function collectSurfaceCss(): string[] {
  const surfacesRoot = path.join(stylesDir, '../surfaces');
  const out: string[] = [];
  function walk(dir: string) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, ent.name);
      if (ent.isDirectory()) walk(p);
      else if (ent.name.endsWith('.css')) out.push(p);
    }
  }
  if (fs.existsSync(surfacesRoot)) walk(surfacesRoot);
  return out;
}

describe('VAL-TOKENS design token contract', () => {
  it('depends on @openburnbar/design-tokens (VAL-TOKENS-001)', () => {
    expect(packageJson.dependencies?.['@openburnbar/design-tokens']).toBeTruthy();
    expect(tokensCss).toMatch(/@openburnbar\/design-tokens/);
  });

  it('keeps app.css free of ad-hoc skin hex (VAL-TOKENS-002)', () => {
    // Skin *palette* overrides belong in skins.css / generated tokens — not app.css.
    expect(appCss).not.toMatch(/:root\[data-skin\s*=/);
    for (const re of BANNED_BRAND_HEX) {
      expect(appCss).not.toMatch(re);
    }
  });

  it('skins layer uses semantic tokens rather than brand hex dumps', () => {
    const hex = skinsCss.match(HEX) ?? [];
    expect(hex).toEqual([]);
    expect(skinsCss).toContain('var(--color-skin-aurora-core)');
  });

  it('surface CSS avoids banned aurora brand hex stops', () => {
    for (const file of collectSurfaceCss()) {
      const css = fs.readFileSync(file, 'utf8');
      for (const re of BANNED_BRAND_HEX) {
        expect(css, path.basename(file)).not.toMatch(re);
      }
    }
  });

  it('reduced-motion contract remains in app.css (VAL-TOKENS-003)', () => {
    expect(appCss).toContain('body.reduced-motion *');
    expect(appCss).toContain('animation: none');
    expect(appCss).toContain('transition: none');
  });

  it('exposes bounded Liquid Glass transparency presets', () => {
    expect(liquidGlassTokensCss).toContain(":root[data-glass-transparency='frostier']");
    expect(liquidGlassTokensCss).toContain(":root[data-glass-transparency='clearer']");
    expect(liquidGlassTokensCss).toContain('--glass-tint-base');
    expect(liquidGlassTokensCss).toContain('--glass-tint-elevated');
  });

  it('declares a dark native-control color scheme for WebKitGTK', () => {
    expect(appCss).toMatch(/:root\s*\{[^}]*color-scheme:\s*dark;/s);
  });
});
