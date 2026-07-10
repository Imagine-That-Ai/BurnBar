import { describe, expect, it } from 'vitest';

import { signalFingerprint } from './classifier.js';

describe('community classifier (linux)', () => {
  it('normalizes extension case in correction fingerprints', () => {
    expect(signalFingerprint({ fileExtensions: ['TS', 'Swift'] })).toBe('ext:swift,ts');
  });
});
