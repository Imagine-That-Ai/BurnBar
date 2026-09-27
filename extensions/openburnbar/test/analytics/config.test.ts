import { describe, expect, it } from 'vitest';

import { resolveAmplitudeApiKey, resolveServerZone } from '../../src/analytics/config';

/**
 * Proves the key seam: with no CI injection (the placeholder is still in place)
 * and no env var, the resolved key is `''` — which makes the recorder dark by
 * construction (no SDK ever constructed). COMMIT ZERO KEYS is enforced here: the
 * source ships only the placeholder, never a real key.
 */
describe('Amplitude key resolution (pre-consent dark by construction)', () => {
  it('returns empty string when the placeholder is unreplaced and no env var is set', () => {
    const key = resolveAmplitudeApiKey({});
    expect(key).toBe('');
  });

  it('falls back to the env var when set (developer-from-source path)', () => {
    const key = resolveAmplitudeApiKey({ BURNBAR_EXTENSION_AMPLITUDE_API_KEY: 'env-injected-key-1234' }); // gitleaks:allow (fake test value, not a real key)
    expect(key).toBe('env-injected-key-1234');
  });

  it('trims whitespace from the env var', () => {
    const key = resolveAmplitudeApiKey({ BURNBAR_EXTENSION_AMPLITUDE_API_KEY: '  spaced-key  ' });
    expect(key).toBe('spaced-key');
  });

  it('the committed source contains the placeholder, NOT a real key', async () => {
    const { readFileSync } = await import('node:fs');
    const { join, dirname } = await import('node:path');
    const { fileURLToPath } = await import('node:url');
    const configPath = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'src', 'analytics', 'config.ts');
    const source = readFileSync(configPath, 'utf8');
    // The placeholder literal must be present (the injection target).
    expect(source).toContain('__AMPLITUDE_API_KEY__');
    // And there must be no obvious baked Amplitude key (32-hex) committed.
    expect(source).not.toMatch(/['"][0-9a-f]{32}['"]/);
  });

  it('official release.yml injects the extension key before tsc', async () => {
    const { readFileSync } = await import('node:fs');
    const { join, dirname } = await import('node:path');
    const { fileURLToPath } = await import('node:url');
    const here = dirname(fileURLToPath(import.meta.url));
    const release = readFileSync(join(here, '..', '..', '..', '..', '.github', 'workflows', 'release.yml'), 'utf8');
    expect(release).toContain('inject-amplitude-extension-config.sh');
    expect(release).toContain('BURNBAR_EXTENSION_AMPLITUDE_API_KEY');
    expect(release.indexOf('inject-amplitude-extension-config.sh')).toBeLessThan(
      release.indexOf('npm run --prefix extensions/openburnbar build')
    );
  });

  it('server zone defaults to US and honours EU only when explicitly set', () => {
    expect(resolveServerZone({})).toBe('US');
    expect(resolveServerZone({ BURNBAR_EXTENSION_AMPLITUDE_SERVER_ZONE: 'EU' })).toBe('EU');
    expect(resolveServerZone({ BURNBAR_EXTENSION_AMPLITUDE_SERVER_ZONE: 'us' })).toBe('US');
  });
});
