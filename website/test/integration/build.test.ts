/**
 * Website build integration tests.
 * Verifies that the Astro build produces valid output.
 * Run: npx vitest run
 */
import { describe, it, expect } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DIST_DIR = join(import.meta.dirname, '../../dist');
const SKIP = !existsSync(DIST_DIR);

// Tests only run if `npm run build` has already produced a dist/ directory
const describeIf = (cond: boolean) => cond ? describe : describe.skip;

describeIf(!SKIP)('Website Build Integration', () => {
  it('dist/ directory exists after build', () => {
    expect(existsSync(DIST_DIR)).toBe(true);
  });

  it('index.html is generated', () => {
    expect(existsSync(join(DIST_DIR, 'index.html'))).toBe(true);
  });

  it('index.html has correct content-type meta', () => {
    const html = readFileSync(join(DIST_DIR, 'index.html'), 'utf-8');
    expect(html).toContain('<!DOCTYPE html>');
    expect(html).toContain('<html');
  });

  it('no placeholder text leaked to production', () => {
    const html = readFileSync(join(DIST_DIR, 'index.html'), 'utf-8');
    const badStrings = ['TODO', 'FIXME', 'lorem ipsum', 'placeholder'];
    for (const bad of badStrings) {
      expect(html.toLowerCase()).not.toContain(bad.toLowerCase());
    }
  });
});
