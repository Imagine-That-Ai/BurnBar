import { describe, expect, it } from 'vitest';
import { formatBytes } from './systemFormat.js';

describe('formatBytes', () => {
  it('formats MiB for fixture db size scale', () => {
    expect(formatBytes(48_234_112)).toMatch(/MiB/);
  });
});