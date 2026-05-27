import { readFileSync } from "node:fs";

import type { ReplayEvaluation, ReplayScenario } from "./replay/types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isReplayScenario(value: unknown): value is ReplayScenario {
  return isRecord(value)
    && typeof value.name === "string"
    && isRecord(value.daemon)
    && Array.isArray(value.daemon.health)
    && isRecord(value.workspace)
    && Array.isArray(value.workspace.capabilities)
    && Array.isArray(value.actions);
}

function isReplayEvaluation(value: unknown): value is ReplayEvaluation {
  return isRecord(value)
    && typeof value.name === "string"
    && Array.isArray(value.checkpoints);
}

export function loadReplayScenario(filePath: string): ReplayScenario {
  const parsed: unknown = JSON.parse(readFileSync(filePath, "utf8"));
  if (!isReplayScenario(parsed)) {
    throw new Error(`Invalid replay scenario fixture: ${filePath}`);
  }
  return parsed;
}

export function loadReplayEvaluation(filePath: string): ReplayEvaluation {
  const parsed: unknown = JSON.parse(readFileSync(filePath, "utf8"));
  if (!isReplayEvaluation(parsed)) {
    throw new Error(`Invalid replay evaluation fixture: ${filePath}`);
  }
  return parsed;
}
