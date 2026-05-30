/**
 * Conversion utilities for workspace RPC results to BurnBarJSONValue.
 */

import type { BurnBarJSONValue } from '../types';
import type {
  BurnBarReadFileResult,
  BurnBarSearchWorkspaceResult,
  BurnBarSearchBurnbarIndexResult,
  OpenBurnBarApplyPatchResult,
  BurnBarRunTerminalResult
} from './types';

export function readFileResultToJSON(result: BurnBarReadFileResult): BurnBarJSONValue {
  return { path: result.path, content: result.content };
}

export function searchWorkspaceResultToJSON(result: BurnBarSearchWorkspaceResult): BurnBarJSONValue {
  return {
    matches: result.matches.map((match) => ({
      path: match.path,
      line: match.line,
      character: match.character,
      preview: match.preview
    }))
  };
}

export function searchBurnbarIndexResultToJSON(result: BurnBarSearchBurnbarIndexResult): BurnBarJSONValue {
  return {
    plan: result.plan,
    aggregateOccurrenceCount: result.aggregateOccurrenceCount ?? null,
    hits: result.hits.map((hit) => ({
      chunkID: hit.chunkID,
      sourceKind: hit.sourceKind,
      sourceID: hit.sourceID,
      title: hit.title,
      snippet: hit.snippet,
      provider: hit.provider ?? null,
      projectName: hit.projectName ?? null
    })),
    degradedMessage: result.degradedMessage ?? null
  };
}

export function applyPatchResultToJSON(result: OpenBurnBarApplyPatchResult): BurnBarJSONValue {
  return { applied: result.applied, changedFiles: result.changedFiles };
}

export function runTerminalResultToJSON(result: BurnBarRunTerminalResult): BurnBarJSONValue {
  return { terminalName: result.terminalName, cwd: result.cwd ?? null };
}
