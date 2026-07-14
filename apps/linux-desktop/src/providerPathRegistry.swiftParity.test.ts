import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LINUX_PROVIDER_PATH_REGISTRY } from './providerPathRegistry';

/**
 * VAL-PARSER-001 ratchet: the TS provider-path registry claims to stay "in sync with
 * OpenBurnBarCore AgentProviderLogDiscovery.swift". Enforce that claim by reading the
 * Swift source directly — the same pattern bridgeRpcContract.test.ts uses against lib.rs.
 * If Swift renames a path, changes a glob, or drops a provider, this fails instead of
 * letting the displayed Linux paths silently diverge from what Core actually discovers.
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const swiftPath = path.resolve(
  here,
  '../../../OpenBurnBarCore/Sources/OpenBurnBarLogParsers/AgentProviderLogDiscovery.swift'
);
const swift = fs.readFileSync(swiftPath, 'utf8');

describe('provider path registry ↔ AgentProviderLogDiscovery.swift parity', () => {
  it('reads the real Swift discovery source (guards against a moved file)', () => {
    expect(swift).toContain('enum AgentProviderLogDiscovery');
    expect(swift).toContain('func filePattern(');
  });

  it.each(LINUX_PROVIDER_PATH_REGISTRY.map((row) => [row.providerId, row]))(
    'row %s matches Swift path, pattern, and provider case',
    (_id, row) => {
      // Logical path fragment (drop the leading ~/) must appear verbatim in Swift discovery.
      const pathFragment = row.logicalPath.replace(/^~\/?/, '');
      expect(
        swift.includes(pathFragment),
        `Swift discovery must contain path fragment "${pathFragment}" for ${row.providerId}`
      ).toBe(true);

      // The watched glob/file the registry advertises must be a real Swift filePattern return.
      expect(
        swift.includes(`"${row.filePattern}"`),
        `Swift filePattern(for:) must return "${row.filePattern}" (row ${row.providerId})`
      ).toBe(true);

      // The parserSourceId must be a real AgentProvider case token in Swift.
      expect(
        new RegExp(`\\b${row.parserSourceId}\\b`).test(swift),
        `Swift must define an AgentProvider case "${row.parserSourceId}" (row ${row.providerId})`
      ).toBe(true);
    }
  );
});
