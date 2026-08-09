/**
 * Versioned package payload contracts.
 *
 * The Linux package payload layout changed between evidence eras:
 *
 * - v1 (historical, mission-002 "reanchor", July 2026): the daemon Swift
 *   runtime shipped under /opt/openburnbar/lib/swift with SQLCipher at
 *   /opt/openburnbar/lib/libsqlcipher.so.0. The surviving receipts
 *   (docs/linux-port/evidence/mission-002-reanchor/smoke) were produced
 *   against that layout and must keep validating against it — historical
 *   receipts are never rewritten to look current.
 *
 * - v2 (current): the payload is rooted under /usr with the runtime at
 *   /usr/lib/openburnbar/swift, native libraries under
 *   /usr/lib/openburnbar/native, and Core resource bundles beside the
 *   daemon in /usr/bin. This matches validate-linux-release-config.mjs and
 *   the signed installed-manifest allowlist.
 *
 * Consumers pick the contract for the artifact/receipt era explicitly, or
 * use detectPayloadContract to classify an existing listing/log. New
 * packages must always be validated against CURRENT_PAYLOAD_CONTRACT.
 */

export const PAYLOAD_CONTRACT_V1_HISTORICAL = Object.freeze({
  id: 'v1-opt-2026-07',
  era: 'historical',
  swiftRuntime: 'opt/openburnbar/lib/swift',
  requiredPatterns: Object.freeze([
    /openburnbar-daemon-launch/u,
    /usr\/bin\/openburnbar-daemon/u,
    /opt\/openburnbar\/lib\/swift/u
  ]),
  // Present in v1 payloads when the packaging host had them; the July smoke
  // receipts record them, so historical receipt validation requires them.
  receiptPatterns: Object.freeze([
    /opt\/openburnbar\/lib\/libsqlcipher\.so/u
  ])
});

export const PAYLOAD_CONTRACT_V2_CURRENT = Object.freeze({
  id: 'v2-usr-current',
  era: 'current',
  swiftRuntime: 'usr/lib/openburnbar/swift',
  requiredPatterns: Object.freeze([
    /openburnbar-daemon-launch/u,
    /usr\/bin\/openburnbar-daemon/u,
    /usr\/lib\/openburnbar\/swift/u,
    /usr\/lib\/openburnbar\/native\/libsqlcipher\.so\.0/u,
    /usr\/lib\/openburnbar\/native\/libopenburnbar_iroh\.so/u,
    /usr\/bin\/OpenBurnBarCore_OpenBurnBarCore\.resources/u
  ]),
  receiptPatterns: Object.freeze([])
});

export const CURRENT_PAYLOAD_CONTRACT = PAYLOAD_CONTRACT_V2_CURRENT;

export const PAYLOAD_CONTRACTS = Object.freeze([
  PAYLOAD_CONTRACT_V1_HISTORICAL,
  PAYLOAD_CONTRACT_V2_CURRENT
]);

/**
 * Classify a package listing or smoke log by payload era. A listing that
 * carries the current /usr runtime root is current even if it also mentions
 * legacy paths in log prose; only listings with the /opt runtime root and no
 * /usr runtime root are historical. Unknown listings return null so callers
 * fail closed instead of guessing.
 */
export function detectPayloadContract(text) {
  if (typeof text !== 'string' || text.length === 0) return null;
  const hasCurrent = /usr\/lib\/openburnbar\/swift/u.test(text);
  const hasHistorical = /opt\/openburnbar\/lib\/swift/u.test(text);
  if (hasCurrent) return PAYLOAD_CONTRACT_V2_CURRENT;
  if (hasHistorical) return PAYLOAD_CONTRACT_V1_HISTORICAL;
  return null;
}

/**
 * Assert a listing or receipt log satisfies the given contract. Returns the
 * list of matched pattern sources for evidence reporting; throws naming the
 * first missing requirement.
 */
export function assertPayloadContract(text, contract, { includeReceiptPatterns = false } = {}) {
  if (typeof text !== 'string' || text.length === 0) {
    throw new Error('payload contract input is empty');
  }
  if (!contract || !Array.isArray(contract.requiredPatterns)) {
    throw new Error('payload contract is malformed');
  }
  const patterns = includeReceiptPatterns
    ? [...contract.requiredPatterns, ...contract.receiptPatterns]
    : [...contract.requiredPatterns];
  const matched = [];
  for (const pattern of patterns) {
    if (!pattern.test(text)) {
      throw new Error(`payload contract ${contract.id} requirement not satisfied: ${pattern.source}`);
    }
    matched.push(pattern.source);
  }
  return matched;
}
