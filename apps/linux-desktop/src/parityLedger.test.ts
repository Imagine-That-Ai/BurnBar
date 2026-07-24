import { describe, expect, it } from 'vitest';
import { PARITY_LEDGER } from './parityLedger.js';

describe('Linux parity ledger', () => {
  it('describes daemon-owned memory review instead of the retired approved-only substitute', () => {
    const row = PARITY_LEDGER.find((entry) => entry.feature === 'Memory review queue');

    expect(row?.linux).toMatch(/pending, approved, rejected, and forgotten transitions/);
    expect(row?.linux).toMatch(/audit hashes/);
    expect(row?.linux).not.toMatch(/shown as approved/);
    expect(row?.substitution).toMatch(/Cross-device review replication/);
  });
});
