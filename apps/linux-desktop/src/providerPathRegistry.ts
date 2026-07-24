import providerIngestionManifest from '../../../contracts/provider-ingestion-catalog.json';

/**
 * Checked Linux provider/path/usage catalog.
 *
 * Rows come directly from `contracts/provider-ingestion-catalog.json`, the
 * same source used to generate Swift discovery. `coverage` describes the
 * ingestion source that is actually registered today; it is deliberately not
 * inferred from a provider logo or a route in the Linux shell.
 *
 * `providerPathRegistry.swiftParity.test.ts` fails when the generated Swift,
 * AgentProvider cases, quota declarations, or parser registrations drift.
 */

export type ProviderIngestionCoverage = 'local-parser' | 'api-backed' | 'unavailable';

export type ProviderPathRow = {
  /** Stable Linux/provider route id used by settings and shell surfaces. */
  providerId: string;
  /** Canonical AgentProvider case token. */
  parserSourceId: string;
  /** User-facing label. */
  displayLabel: string;
  /** Canonical vendor and historical aliases from the shared manifest. */
  aliases: readonly string[];
  /** Logical path (tilde form) used in docs and settings. */
  logicalPath: string;
  /** Glob / file pattern the canonical discovery table advertises. */
  filePattern: string;
  /** How usage is sourced on the macOS gold-standard path. */
  coverage: ProviderIngestionCoverage;
  /** Honest explanation shown beside the path in Settings/onboarding. */
  coverageNote: string;
  /** How XDG/home expansion applies. */
  xdgBehavior: 'home-relative' | 'xdg-config-code' | 'xdg-data' | 'no-local-logs';
  /** Whether symlink targets keep session identity on resolved path. */
  symlinkBehavior: 'identity-on-resolved-path';
};

/**
 * Canonical provider path and ingestion coverage rows.
 *
 * There are 33 canonical AgentProvider cases and 28 ParserRegistry entries.
 * The five rows without a local parser remain visible with an explicit
 * `api-backed` or `unavailable` state; they must not be presented as parsed
 * local usage until a real source is wired.
 */
type ProviderIngestionManifest = {
  schemaVersion: 1;
  providers: Array<{
    providerId: string;
    agentProviderCase: string;
    displayLabel: string;
    aliases: string[];
    paths: { linux: string; macos: string };
    filePattern: string;
    ingestion: ProviderIngestionCoverage;
    coverageNote: string;
    xdgBehavior: ProviderPathRow['xdgBehavior'];
    symlinkBehavior: ProviderPathRow['symlinkBehavior'];
    quotaSignal: boolean;
  }>;
};

const manifest = providerIngestionManifest as ProviderIngestionManifest;
if (manifest.schemaVersion !== 1) {
  throw new Error('Unsupported provider ingestion catalog schema.');
}

export const LINUX_PROVIDER_PATH_REGISTRY: readonly ProviderPathRow[] = manifest.providers.map(
  (provider) => ({
    providerId: provider.providerId,
    parserSourceId: provider.agentProviderCase,
    displayLabel: provider.displayLabel,
    aliases: provider.aliases,
    logicalPath: provider.paths.linux,
    filePattern: provider.filePattern,
    coverage: provider.ingestion,
    coverageNote: provider.coverageNote,
    xdgBehavior: provider.xdgBehavior,
    symlinkBehavior: provider.symlinkBehavior
  })
);

export type ProviderCoverageCounts = {
  total: number;
  localParser: number;
  apiBacked: number;
  unavailable: number;
};

export function providerCoverageCounts(): ProviderCoverageCounts {
  return LINUX_PROVIDER_PATH_REGISTRY.reduce<ProviderCoverageCounts>(
    (counts, row) => {
      counts.total += 1;
      if (row.coverage === 'local-parser') counts.localParser += 1;
      if (row.coverage === 'api-backed') counts.apiBacked += 1;
      if (row.coverage === 'unavailable') counts.unavailable += 1;
      return counts;
    },
    { total: 0, localParser: 0, apiBacked: 0, unavailable: 0 }
  );
}

export function providerCoverageSummary(): string {
  const counts = providerCoverageCounts();
  return `${counts.localParser} local parsers, ${counts.apiBacked} API-backed sources, ${counts.unavailable} unavailable local sources (${counts.total} canonical providers)`;
}

export function resolveProviderLogicalPath(
  logicalPath: string,
  home: string,
  env: { XDG_CONFIG_HOME?: string; XDG_DATA_HOME?: string } = {}
): string {
  if (!logicalPath.startsWith('~')) return logicalPath;
  const rest = logicalPath === '~' ? '' : logicalPath.slice(1); // keep leading /
  // XDG-aware expansion for known prefixes under ~/.config and ~/.local/share.
  if (rest.startsWith('/.config/') && env.XDG_CONFIG_HOME) {
    return env.XDG_CONFIG_HOME + rest.slice('/.config'.length);
  }
  if (rest.startsWith('/.local/share/') && env.XDG_DATA_HOME) {
    return env.XDG_DATA_HOME + rest.slice('/.local/share'.length);
  }
  return home + rest;
}

export function providerPathById(providerId: string): ProviderPathRow | undefined {
  const normalized = providerId.trim().toLowerCase().replace(/[\s._-]+/g, '');
  if (!normalized) return undefined;

  // The daemon catalog uses vendor IDs while the usage/path oracle uses
  // AgentProvider route IDs. Keep the same aliases as
  // AgentProvider.fromCatalogProviderID so a catalog row can always resolve
  // to its canonical path and ingestion coverage without guessing from a logo.
  const canonicalID = normalized;
  return LINUX_PROVIDER_PATH_REGISTRY.find((row) => {
    const rowTokens = [row.providerId, row.parserSourceId, row.displayLabel, ...row.aliases]
      .map((value) => value.toLowerCase().replace(/[\s._-]+/g, ''));
    return rowTokens.includes(canonicalID);
  });
}

/** Display list used by settings / onboarding. */
export function providerDisplayPaths(): string[] {
  return LINUX_PROVIDER_PATH_REGISTRY.map((row) => row.logicalPath);
}
