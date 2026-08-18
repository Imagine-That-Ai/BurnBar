import assert from 'node:assert/strict';
import test from 'node:test';
import { renderMobileParityLedger } from './lib/mobile-parity-validate.mjs';

test('renders claim, VAL rows, and capability rows deterministically', () => {
  const ledger = {
    semantics: {
      productParityClaim: false,
      programStatus: 'mobile parity remediation in progress',
      baselineSha: '3f127f7da28f590441c46e0674dac7f27a04b7aa'
    },
    rows: [
      {
        id: 'VAL-MOB-001',
        kind: 'val-contract',
        status: 'blocked',
        evidenceFreshness: 'blocked',
        owner: { implementation: 'mobile-apps', validation: 'mobile-parity' },
        missingPrerequisite: 'named device',
        promotionCriterion: 'bind candidate'
      },
      {
        id: 'CAP-pulse.overview',
        kind: 'capability',
        capabilityId: 'pulse.overview',
        family: 'pulse',
        status: 'implemented'
      }
    ]
  };
  const registry = {
    capabilities: [{
      capabilityId: 'pulse.overview',
      family: 'pulse',
      kind: 'capability',
      entitlement: 'none',
      evidenceFloor: ['unit'],
      routeIds: ['route.shell.pulse']
    }]
  };
  const first = renderMobileParityLedger(ledger, registry);
  const second = renderMobileParityLedger(ledger, registry);
  assert.equal(first, second);
  assert.match(first, /Product parity claim: \*\*false\*\*/);
  assert.match(first, /mobile parity remediation in progress/);
  assert.match(first, /\| VAL-MOB-001 \| blocked \|/);
  assert.match(first, /\| pulse.overview \| pulse \| capability \| implemented \|/);
  assert.match(first, /validate-mobile-parity\.mjs --allow-blocked/);
});
