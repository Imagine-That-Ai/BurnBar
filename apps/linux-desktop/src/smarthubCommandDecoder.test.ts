import { describe, expect, it } from 'vitest';
import { decodeSmartHubCommandResponse } from './tauriBridge.js';

describe('P28 SmartHub command decoder', () => {
  it('decodes discovery results while preserving an empty Avahi transcript', () => {
    expect(
      decodeSmartHubCommandResponse({
        operation: 'discover',
        payload: [
          {
            adapter: 'smart_hub_bridge',
            serviceType: '_openburnbar-peer._tcp',
            instances: [],
            rawTranscript: ''
          }
        ]
      })
    ).toEqual({
      operation: 'discover',
      payload: [
        {
          adapter: 'smart_hub_bridge',
          serviceType: '_openburnbar-peer._tcp',
          instances: [],
          rawTranscript: ''
        }
      ]
    });
  });

  it('decodes status metadata as string-only details', () => {
    const result = decodeSmartHubCommandResponse({
      operation: 'status',
      payload: {
        adapter: 'smart_hub_bridge',
        status: 'blocked_bridge_not_reachable',
        blocker: 'Start the bridge.',
        bridge_listen: '127.0.0.1:8787'
      }
    });
    expect(result.operation).toBe('status');
    if (result.operation === 'status') {
      expect(result.payload.details.bridge_listen).toBe('127.0.0.1:8787');
    }
  });

  it('rejects unknown operations and non-string status fields', () => {
    expect(() => decodeSmartHubCommandResponse({ operation: 'status --json', payload: {} })).toThrow(
      /not allowlisted/
    );
    expect(() =>
      decodeSmartHubCommandResponse({
        operation: 'status',
        payload: { adapter: 'smart_hub_bridge', status: 'ok', online: true }
      })
    ).toThrow(/must be a string/);
  });

  it('requires a complete command response rather than defaulting malformed payloads', () => {
    expect(() => decodeSmartHubCommandResponse({ operation: 'discover' })).toThrow(/payload is missing/);
    expect(() => decodeSmartHubCommandResponse({ operation: 'discover', payload: {} })).toThrow(
      /payload must be an array/
    );
    expect(() =>
      decodeSmartHubCommandResponse({
        operation: 'discover',
        payload: [{ adapter: 'smart_hub_bridge', serviceType: '_openburnbar-peer._tcp', instances: [] }]
      })
    ).toThrow(/rawTranscript/);
  });
});
