import type {
  InsightsQualitativeCapability,
  UsageInsightsQualitativeCitation,
  UsageInsights,
  UsageInsightsSource
} from '../../tauriBridge.js';

export type InsightsEvidenceState = 'verified' | 'unavailable';

export type InsightsEvidence = {
  sourceID: string;
  sourceKind: UsageInsightsSource['kind'] | 'unknown';
  label: string;
  state: InsightsEvidenceState;
  detail: string;
};

export type InsightsFreshnessState = 'fresh' | 'stale' | 'unavailable';

export type InsightsFreshness = {
  state: InsightsFreshnessState;
  generatedAt: string | null;
  detail: string;
};

/**
 * Qualitative analysis is the only Insights payload with a daemon-issued
 * generated-at timestamp. Keep the freshness claim scoped to that analysis;
 * never infer an age for the aggregate usage response. Invalid or future
 * timestamps remain unavailable rather than looking fresh by accident.
 */
export function resolveInsightsFreshness(
  data: UsageInsights,
  now: Date = new Date(),
  staleAfterMs = 24 * 60 * 60 * 1000
): InsightsFreshness {
  const generatedAt = data.qualitative?.analysis?.generatedAt ?? null;
  if (!generatedAt) {
    return {
      state: 'unavailable',
      generatedAt: null,
      detail: 'No daemon generated-at timestamp is available for the qualitative brief.'
    };
  }
  const generatedMillis = Date.parse(generatedAt);
  const nowMillis = now.getTime();
  if (!Number.isFinite(generatedMillis) || !Number.isFinite(nowMillis) || generatedMillis > nowMillis) {
    return {
      state: 'unavailable',
      generatedAt,
      detail: 'The qualitative brief timestamp is invalid or ahead of the local clock.'
    };
  }
  const age = nowMillis - generatedMillis;
  if (age >= staleAfterMs) {
    return {
      state: 'stale',
      generatedAt,
      detail: 'The qualitative brief is older than the current freshness window. Refresh before relying on it.'
    };
  }
  return {
    state: 'fresh',
    generatedAt,
    detail: 'The qualitative brief was generated within the current freshness window.'
  };
}

const VALID_SOURCES: Record<UsageInsightsSource['id'], Pick<UsageInsightsSource, 'kind' | 'label'>> = {
  'daemon.usage.recent': { kind: 'daemon-method', label: 'live daemon usage insights' },
  'daemon.usage.insights': { kind: 'daemon-method', label: 'daemon-authored qualitative insights' },
  'fixture.usage.insights': { kind: 'fixture', label: 'fixture transcript' }
};

/**
 * Resolve only source IDs that belong to a known Linux response authority.
 * A missing or malformed source must remain visibly unavailable instead of
 * becoming a renderer-generated citation that looks authoritative.
 */
export function resolveInsightsEvidence(data: UsageInsights, sourceLabel: string): InsightsEvidence {
  const source = data.source;
  const definition = source ? VALID_SOURCES[source.id] : undefined;
  if (source && definition && source.kind === definition.kind) {
    return {
      sourceID: source.id,
      sourceKind: source.kind,
      label: definition.label,
      state: 'verified',
      detail:
        definition.kind === 'fixture'
          ? 'Local fixture transcript; not evidence from a running daemon.'
          : source.id === 'daemon.usage.insights'
            ? 'Authored by the daemon from a bounded local usage digest; no transcript or credential data leaves the daemon.'
            : 'Aggregated from the daemon.usage.recent response.'
    };
  }
  return {
    sourceID: 'unavailable',
    sourceKind: 'unknown',
    label: sourceLabel,
    state: 'unavailable',
    detail: 'The response did not include a validated Insights source ID.'
  };
}

export function resolveQualitativeCapability(data: UsageInsights): InsightsQualitativeCapability {
  const capability = data.qualitative;
  if (!capability) {
    return {
      state: 'unavailable',
      reason: 'The Linux daemon has no qualitative-analysis RPC.'
    };
  }
  if (capability.state === 'available' || capability.state === 'degraded' || capability.state === 'unavailable') {
    return capability;
  }
  return {
    state: 'unavailable',
    reason: 'The qualitative-analysis capability returned an unknown state.'
  };
}

/**
 * Build the bounded chat handoff used by Linux citation chips.
 *
 * The daemon intentionally returns opaque citation IDs rather than renderer
 * routes. Keep that boundary intact: the shell carries both the label and ID
 * into chat, where the daemon can resolve the evidence against its current
 * authority. Do not turn an ID into a guessed URL or local file path.
 */
export function insightsCitationPrompt(citation: UsageInsightsQualitativeCitation): string {
  return `Explain the Insights evidence "${citation.label}" (citation ${citation.id}) from the current daemon response.`;
}

/**
 * Preserve citation order while removing duplicate IDs. The macOS brief shows
 * a compact chip flow; the Linux inspector follows the same bounded shape so
 * a repeated citation cannot flood the workspace.
 */
export function uniqueInsightsCitations(
  citations: readonly UsageInsightsQualitativeCitation[],
  limit = 8
): UsageInsightsQualitativeCitation[] {
  const seen = new Set<string>();
  const unique: UsageInsightsQualitativeCitation[] = [];
  for (const citation of citations) {
    if (seen.has(citation.id)) continue;
    seen.add(citation.id);
    unique.push(citation);
    if (unique.length >= limit) break;
  }
  return unique;
}
