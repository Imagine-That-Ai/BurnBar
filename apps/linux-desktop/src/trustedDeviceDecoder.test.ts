import { describe, expect, it } from 'vitest';
import { mapTrustedDeviceList, mapTrustedDeviceMutation } from './tauriBridgeSystemDecoders.js';

describe('trusted-device decoders', () => {
  it('maps redacted device state and preserves optional fingerprint', () => {
    expect(mapTrustedDeviceList({
      ok: true,
      devices: [{
        deviceID: 'ipad-1',
        displayName: 'Alberto iPad',
        platform: 'iPadOS',
        trustState: 'pending',
        isCurrentDevice: false,
        safetyFingerprint: 'abc123'
      }]
    })).toEqual({
      ok: true,
      devices: [{
        deviceId: 'ipad-1',
        displayName: 'Alberto iPad',
        platform: 'iPadOS',
        trustState: 'pending',
        isCurrentDevice: false,
        safetyFingerprint: 'abc123'
      }]
    });
  });

  it('rejects duplicate or malformed device records', () => {
    expect(() => mapTrustedDeviceList({
      devices: [
        { deviceID: 'ipad-1', displayName: 'iPad', platform: 'iPadOS', trustState: 'trusted' },
        { deviceID: 'ipad-1', displayName: 'iPad copy', platform: 'iPadOS', trustState: 'trusted' }
      ]
    })).toThrow(/duplicate/i);
    expect(() => mapTrustedDeviceList({
      devices: [{ deviceID: 'ipad-1', displayName: 'iPad\nunsafe', platform: 'iPadOS', trustState: 'trusted' }]
    })).toThrow(/display name/i);
  });

  it('binds mutation response to a bounded state', () => {
    expect(mapTrustedDeviceMutation({
      result: { ok: true, deviceID: 'ipad-1', trustState: 'revoked', alreadyInState: false }
    })).toEqual({ ok: true, deviceId: 'ipad-1', trustState: 'revoked', alreadyInState: false });
    expect(() => mapTrustedDeviceMutation({
      deviceID: 'ipad-1', trustState: 'unknown'
    })).toThrow(/state/i);
  });
});
