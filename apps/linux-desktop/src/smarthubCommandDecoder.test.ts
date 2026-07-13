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

  it('rejects oversized and control-character payloads before renderer display', () => {
    expect(() => decodeSmartHubCommandResponse({
      operation: 'status',
      payload: { adapter: 'smart_hub_bridge', status: 'ok', detail: 'x'.repeat(32_769) }
    })).toThrow(/payload limit/);
    expect(() => decodeSmartHubCommandResponse({
      operation: 'status',
      payload: { adapter: 'smart_hub_bridge', status: 'ok', detail: 'safe\u0000text' }
    })).toThrow(/control character/);
    expect(() => decodeSmartHubCommandResponse({
      operation: 'discover',
      payload: Array.from({ length: 129 }, () => ({
        adapter: 'smart_hub_bridge', serviceType: '_openburnbar-peer._tcp', instances: [], rawTranscript: ''
      }))
    })).toThrow(/item limit/);
  });

  it('accepts typed test, cast, and device operations without opening an argument escape hatch', () => {
    for (const operation of ['test', 'cast', 'device'] as const) {
      expect(decodeSmartHubCommandResponse({
        operation,
        payload: { adapter: 'smart_hub_bridge', status: 'blocked', detail: '' }
      })).toMatchObject({ operation, payload: { status: 'blocked' } });
    }
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
