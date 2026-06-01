/**
 * Hermes Gateway promo — copy & link coverage.
 * Verifies the BurnBar Cloud Hermes Gateway advertisement renders on every
 * promoted marketing surface, points at the real approval page, and uses the
 * real Hermes logo asset.
 * Run after a build: `npm run build:offline && npx vitest run`
 */
import { describe, it, expect } from 'vitest';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DIST_DIR = join(import.meta.dirname, '../../dist');
const SKIP = !existsSync(DIST_DIR);
const describeIf = (cond: boolean) => (cond ? describe : describe.skip);

// Pages where the promo must appear (Astro emits <route>/index.html).
const PROMOTED_SURFACES: Record<string, string> = {
  home: 'index.html',
  product: join('product', 'index.html'),
  pricing: join('pricing', 'index.html')
};

const read = (rel: string) => readFileSync(join(DIST_DIR, rel), 'utf-8');

describeIf(!SKIP)('Hermes Gateway promo', () => {
  for (const [surface, file] of Object.entries(PROMOTED_SURFACES)) {
    describe(surface, () => {
      it('renders the gateway headline', () => {
        const html = read(file);
        expect(html).toContain('Connect Hermes through BurnBar');
      });

      it('links to the Hermes connect/approval page', () => {
        const html = read(file);
        expect(html).toContain('href="/hermes/connect"');
      });

      it('uses the real Hermes logo asset', () => {
        const html = read(file);
        expect(html).toContain('/brand/providers/hermes.png');
      });

      it('states Cloud / Cloud Pro eligibility', () => {
        const html = read(file);
        expect(html).toMatch(/Cloud\s*(&amp;|&)\s*Cloud Pro/);
      });

      it('frames BurnBar alongside Telegram and Signal', () => {
        const html = read(file);
        expect(html).toContain('Telegram');
        expect(html).toContain('Signal');
      });
    });
  }

  it('the Hermes connect/approval page is published', () => {
    expect(existsSync(join(DIST_DIR, 'hermes', 'connect', 'index.html'))).toBe(true);
  });

  it('the Hermes logo asset is shipped to dist', () => {
    expect(existsSync(join(DIST_DIR, 'brand', 'providers', 'hermes.png'))).toBe(true);
  });
});
