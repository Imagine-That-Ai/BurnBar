import { describe, expect, it } from 'vitest';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import providerManifest from '../../../contracts/provider-ingestion-catalog.json';
import { LINUX_PROVIDER_PATH_REGISTRY } from './providerPathRegistry.js';

/** VAL-PARSER-001/002: one manifest drives Linux display and Swift discovery. */
const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '../../..');
const swiftDiscovery = fs.readFileSync(
  path.join(repoRoot, 'OpenBurnBarCore/Sources/OpenBurnBarLogParsers/AgentProviderLogDiscovery.swift'),
  'utf8'
);
const generatedSwift = fs.readFileSync(
  path.join(
    repoRoot,
    'OpenBurnBarCore/Sources/OpenBurnBarParserSupport/AgentProviderIngestionCatalog.generated.swift'
  ),
  'utf8'
);
const swiftProvider = fs.readFileSync(
  path.join(repoRoot, 'OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AgentProvider.swift'),
  'utf8'
);
const parserRegistry = fs.readFileSync(
  path.join(repoRoot, 'AgentLens/Services/UsageAggregation/ParserRegistry.swift'),
  'utf8'
);

function canonicalProviderCases(source: string): string[] {
  return Array.from(source.matchAll(/^    case ([A-Za-z0-9]+)\s*=/gm), (match) => match[1]!);
}

function parserRegistrations(source: string): string[] {
  return Array.from(source.matchAll(/parsers\[\.([A-Za-z0-9]+)\]\s*=/g), (match) => match[1]!);
}

function quotaProviderCases(source: string): string[] {
  const start = source.indexOf('public static let quotaSignalProviders');
  const end = source.indexOf('\n    ]', start);
  if (start < 0 || end < 0) throw new Error('Missing AgentProvider.quotaSignalProviders');
  return Array.from(source.slice(start, end).matchAll(/\.([A-Za-z0-9]+)/g), (match) => match[1]!);
}

function accountPartition(rawValue: string | null): string {
  const trimmed = rawValue?.trim() ?? '';
  if (!trimmed) return '';
  if (/^acct_sha256_[0-9a-fA-F]{24}$/.test(trimmed)) return trimmed;
  return `acct_sha256_${crypto.createHash('sha256').update(trimmed).digest('hex').slice(0, 24)}`;
}

describe('provider ingestion manifest parity', () => {
  it('keeps the checked-in Swift contract generated from the authoritative manifest', () => {
    expect(() =>
      execFileSync('node', ['scripts/generate-provider-ingestion-catalog.mjs', '--check'], {
        cwd: repoRoot,
        stdio: 'pipe'
      })
    ).not.toThrow();
    expect(swiftDiscovery).toContain('AgentProviderIngestionCatalog.entry(for: provider)');
    expect(swiftDiscovery).not.toContain('switch provider');
  });

  it('contains every canonical AgentProvider case exactly once', () => {
    const canonicalCases = canonicalProviderCases(swiftProvider);
    const manifestCases = providerManifest.providers.map((provider) => provider.agentProviderCase);
    expect(canonicalCases).toHaveLength(37);
    expect(new Set(canonicalCases).size).toBe(canonicalCases.length);
    expect([...manifestCases].sort()).toEqual([...canonicalCases].sort());
    expect(new Set(providerManifest.providers.map((provider) => provider.providerId)).size).toBe(37);
  });

  it('generates both platform paths, patterns, and coverage for every provider', () => {
    for (const provider of providerManifest.providers) {
      expect(generatedSwift).toContain(`provider: .${provider.agentProviderCase}`);
      expect(generatedSwift).toContain(JSON.stringify(provider.paths.linux));
      expect(generatedSwift).toContain(JSON.stringify(provider.paths.macos));
      expect(generatedSwift).toContain(JSON.stringify(provider.filePattern));
      expect(LINUX_PROVIDER_PATH_REGISTRY.find((row) => row.providerId === provider.providerId)).toMatchObject({
        parserSourceId: provider.agentProviderCase,
        logicalPath: provider.paths.linux,
        filePattern: provider.filePattern,
        coverage: provider.ingestion
      });
    }
  });

  it('matches ParserRegistry and AgentProvider quota declarations exactly', () => {
    const registered = [...new Set(parserRegistrations(parserRegistry))].sort();
    const local = providerManifest.providers
      .filter((provider) => provider.ingestion === 'local-parser')
      .map((provider) => provider.agentProviderCase)
      .sort();
    const quota = providerManifest.providers
      .filter((provider) => provider.quotaSignal)
      .map((provider) => provider.agentProviderCase)
      .sort();
    expect(registered).toEqual(local);
    expect([...new Set(quotaProviderCases(swiftProvider))].sort()).toEqual(quota);
  });

  it('pins shared identity, timestamp, dedup, token, cost, and quota vectors', () => {
    const providers = new Map(providerManifest.providers.map((provider) => [provider.agentProviderCase, provider]));
    for (const vector of providerManifest.goldenUsageVectors) {
      const identityKey = [
        vector.providerRawValue,
        vector.sessionId,
        vector.model,
        vector.sourceDeviceId?.trim() ?? '',
        accountPartition(vector.providerAccountId)
      ].join('\u001f');
      const billed = [
        vector.inputTokens,
        vector.outputTokens,
        vector.cacheCreationTokens,
        vector.cacheReadTokens,
        vector.reasoningTokens
      ].reduce((total, value) => total + Math.max(0, value), 0);
      expect(identityKey).toBe(vector.expected.identityKey);
      // The Swift contract suite executes TokenUsage.deterministicID against these same
      // vectors. Linux validates the shared catalog shape without reimplementing UUIDv5.
      expect(vector.expected.deterministicId).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u
      );
      expect(billed).toBe(vector.expected.billedTotalTokens);
      expect(vector.costUSD).toBe(vector.expected.costUSD);
      expect(new Date(vector.startTime).toISOString()).toBe(vector.startTime);
      expect(new Date(vector.endTime).toISOString()).toBe(vector.endTime);
      expect(providers.get(vector.providerCase)?.quotaSignal).toBe(vector.expected.quotaSignal);
    }
  });
});
