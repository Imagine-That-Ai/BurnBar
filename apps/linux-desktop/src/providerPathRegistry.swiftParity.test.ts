import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { LINUX_PROVIDER_PATH_REGISTRY } from './providerPathRegistry.js';

/**
 * VAL-PARSER-001/002 ratchet.
 *
 * The Linux catalog is intentionally checked against the committed Swift
 * sources rather than a second hand-maintained list. This catches both sides
 * of drift: a new AgentProvider case without a Linux row and a stale Linux
 * row whose discovery path, pattern, or parser registration was removed.
 */
const here = path.dirname(fileURLToPath(import.meta.url));
const coreRoot = path.resolve(here, '../../../OpenBurnBarCore/Sources');
const swiftDiscoveryPath = path.join(
  coreRoot,
  'OpenBurnBarCore/SharedModels/AgentProviderLogDiscovery.swift'
);
const swiftProviderPath = path.join(
  coreRoot,
  'OpenBurnBarKernel/SharedModels/AgentProvider.swift'
);
const parserRegistryPath = path.resolve(
  here,
  '../../../AgentLens/Services/UsageAggregation/ParserRegistry.swift'
);
const swiftDiscovery = fs.readFileSync(swiftDiscoveryPath, 'utf8');
const swiftProvider = fs.readFileSync(swiftProviderPath, 'utf8');
const parserRegistry = fs.readFileSync(parserRegistryPath, 'utf8');

function canonicalProviderCases(source: string): string[] {
  return Array.from(source.matchAll(/^    case ([A-Za-z0-9]+)\s*=/gm), (match) => match[1]!);
}

function parserRegistrations(source: string): string[] {
  return Array.from(source.matchAll(/parsers\[\.([A-Za-z0-9]+)\]\s*=/g), (match) => match[1]!);
}

function functionSection(source: string, functionName: string): string {
  const start = source.indexOf(`func ${functionName}`);
  if (start < 0) throw new Error(`Missing Swift function ${functionName}`);
  const next = source.indexOf('\n    public static func ', start + 5);
  return source.slice(start, next < 0 ? source.length : next);
}

function caseSection(source: string, providerCase: string): string {
  const escapedCase = providerCase.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Swift groups cases that share one path/pattern (for example
  // `case .factory, .claudeCode, ...`). Capture the whole case line so the
  // returned section includes the shared return value.
  const match = source.match(new RegExp(`^[ \\t]*case [^\\n]*\\.${escapedCase}(?=,|:)`, 'm'));
  const start = match?.index ?? -1;
  if (start < 0) throw new Error(`Missing Swift discovery case .${providerCase}`);
  const next = source.indexOf('\n        case .', start + 6);
  return source.slice(start, next < 0 ? source.length : next);
}

const canonicalCases = canonicalProviderCases(swiftProvider);
const registeredParsers = parserRegistrations(parserRegistry);
const logicalPathSection = functionSection(swiftDiscovery, 'logicalLogDirectory');
const filePatternSection = functionSection(swiftDiscovery, 'filePattern');

describe('provider path and usage catalog ↔ canonical Swift sources', () => {
  it('reads the real canonical sources', () => {
    expect(swiftDiscovery).toContain('enum AgentProviderLogDiscovery');
    expect(swiftProvider).toContain('public enum AgentProvider:');
    expect(parserRegistry).toContain('enum ParserRegistry');
  });

  it('contains every canonical AgentProvider case exactly once', () => {
    const sourceCases = [...new Set(canonicalCases)].sort();
    const catalogCases = LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.parserSourceId).sort();
    expect(canonicalCases).toHaveLength(33);
    expect(new Set(canonicalCases).size).toBe(canonicalCases.length);
    expect(catalogCases).toEqual(sourceCases);
    expect(new Set(LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.providerId)).size).toBe(33);
  });

  it('matches every Linux logical path and file pattern in AgentProviderLogDiscovery', () => {
    for (const row of LINUX_PROVIDER_PATH_REGISTRY) {
      const pathCase = caseSection(logicalPathSection, row.parserSourceId);
      const patternCase = caseSection(filePatternSection, row.parserSourceId);
      expect(pathCase, `Linux discovery path for .${row.parserSourceId}`).toContain(row.logicalPath);
      expect(patternCase, `filePattern(for: .${row.parserSourceId})`).toContain(`"${row.filePattern}"`);
    }
  });

  it('matches the 27 registered local parsers and exposes the six missing sources', () => {
    const parserCases = [...new Set(registeredParsers)].sort();
    const localCatalogCases = LINUX_PROVIDER_PATH_REGISTRY
      .filter((row) => row.coverage === 'local-parser')
      .map((row) => row.parserSourceId)
      .sort();
    const nonParserCases = LINUX_PROVIDER_PATH_REGISTRY
      .filter((row) => row.coverage !== 'local-parser')
      .map((row) => row.parserSourceId)
      .sort();

    expect(registeredParsers).toHaveLength(27);
    expect(parserCases).toEqual(localCatalogCases);
    expect(nonParserCases).toEqual(['deepSeek', 'mimo', 'omp', 'openAI', 'openBurnBar', 'openClaude']);
    for (const row of LINUX_PROVIDER_PATH_REGISTRY.filter((candidate) => candidate.coverage !== 'local-parser')) {
      expect(row.coverageNote).toMatch(/No local parser|No ParserRegistry entry/);
    }
  });
});
