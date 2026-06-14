/**
 * Conversion utilities for workspace RPC results to BurnBarJSONValue.
 */

import type { BurnBarJSONValue } from '../types';
import type {
  BurnBarReadFileResult,
  BurnBarSearchWorkspaceResult,
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

export function applyPatchResultToJSON(result: OpenBurnBarApplyPatchResult): BurnBarJSONValue {
  return { applied: result.applied, changedFiles: result.changedFiles };
}

export function runTerminalResultToJSON(result: BurnBarRunTerminalResult): BurnBarJSONValue {
  return { terminalName: result.terminalName, cwd: result.cwd ?? null };
}
