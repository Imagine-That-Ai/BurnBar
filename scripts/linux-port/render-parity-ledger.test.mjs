import assert from 'node:assert/strict';
import test from 'node:test';
import { renderParityLedger } from './render-parity-ledger.mjs';

test('renders deterministic claim, product, and environment status', () => {
  const ledger = {
    historyLedger: 'docs/linux-port/parity-ledger-history.json',
    semantics: {
      productParityClaim: false,
      goldStandard: 'OpenBurnBar for macOS',
      audit: 'docs/linux-port/AUDIT.md'
    },
    rows: [{ id: 'P-01', requirementId: 'P-01', tier: 'A', status: 'blocked', owner: 'release', promotionCriterion: 'prove it' }],
    environmentCoverage: [{ id: 'ubuntu', status: 'blocked' }]
  };
  const requirements = {
    requirements: [{ id: 'P-01', area: 'release-integrity', priority: 'Critical' }],
    minimumSupportMatrix: [{ id: 'ubuntu', os: 'Ubuntu', desktop: 'GNOME', session: 'Wayland', architecture: 'x86_64' }]
  };
  const first = renderParityLedger(ledger, requirements);
  const second = renderParityLedger(ledger, requirements);
  assert.equal(first, second);
  assert.match(first, /Product parity claim: \*\*false\*\*/);
  assert.match(first, /\| P-01 \| release-integrity \| Critical \| A \| blocked \|/);
  assert.match(first, /\| ubuntu \| Ubuntu \| GNOME \| Wayland \| x86_64 \| blocked \|/);
});
