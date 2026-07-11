import { describe, expect, it } from 'vitest';
import { makeAvailableRuntimeCapabilityManifest } from './testing/bridgeStubs.js';
import {
  capabilityBlocksSurface,
  decodeRuntimeCapabilityManifest,
  findRuntimeCapability
} from './runtimeCapabilities.js';

describe('runtime capability manifest', () => {
  it('accepts a complete versioned manifest', () => {
    const source = makeAvailableRuntimeCapabilityManifest();
    const decoded = decodeRuntimeCapabilityManifest(source);
    expect(decoded).toEqual(source);
    expect(findRuntimeCapability(decoded, 'chat.gateway')?.state).toBe('available');
  });

  it('rejects duplicate, missing, unknown, and unsupported entries', () => {
    const duplicate = makeAvailableRuntimeCapabilityManifest();
    duplicate.capabilities[1] = duplicate.capabilities[0];
    expect(() => decodeRuntimeCapabilityManifest(duplicate)).toThrow(/duplicate_id/);

    const missing = makeAvailableRuntimeCapabilityManifest();
    missing.capabilities.pop();
    expect(() => decodeRuntimeCapabilityManifest(missing)).toThrow(/missing_ids/);

    const unknown = makeAvailableRuntimeCapabilityManifest() as unknown as {
      capabilities: Array<Record<string, unknown>>;
    };
    unknown.capabilities[0].id = 'unknown.capability';
    expect(() => decodeRuntimeCapabilityManifest(unknown)).toThrow(/unknown_id/);

    const unsupported = { ...makeAvailableRuntimeCapabilityManifest(), schemaVersion: 2 };
    expect(() => decodeRuntimeCapabilityManifest(unsupported)).toThrow(/unsupported_schema/);
  });

  it('blocks unavailable and policy-blocked surfaces but permits degraded surfaces', () => {
    const manifest = makeAvailableRuntimeCapabilityManifest();
    const entry = manifest.capabilities[0];
    expect(capabilityBlocksSurface({ ...entry, state: 'unavailable' })).toBe(true);
    expect(capabilityBlocksSurface({ ...entry, state: 'blocked' })).toBe(true);
    expect(capabilityBlocksSurface({ ...entry, state: 'degraded' })).toBe(false);
  });
});
