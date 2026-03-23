import type { BurnBarCatalog, BurnBarHealthResponse, BurnBarState } from "../../src/types";
import type { BurnBarWorkspaceCapabilities } from "../../src/workspace/types";

export interface ReplayStepResult<T> {
  result: T;
}

export interface ReplayStepError {
  error: string;
}

export type ReplayStep<T> = ReplayStepResult<T> | ReplayStepError;

export interface ReplayAction {
  type: "refresh" | "repair";
  label: string;
}

export interface ReplayScenario {
  name: string;
  daemon: {
    health: ReplayStep<BurnBarHealthResponse>[];
    catalog?: ReplayStep<BurnBarCatalog>[];
  };
  workspace: {
    capabilities: ReplayStep<BurnBarWorkspaceCapabilities>[];
  };
  repair?: ReplayStep<{
    message: string;
  }>;
  actions: ReplayAction[];
}

export interface ReplayCheckpoint {
  label: string;
  snapshot: BurnBarState;
  healthRows: Array<{
    id: string;
    label: string;
    value: string;
    icon: "pass" | "warning" | "pulse" | "note";
    tooltip?: string;
  }>;
  runDetailRows: Array<{
    id: string;
    label: string;
    value: string;
  }>;
  actionResult?: {
    message: string;
  };
}

export interface ReplayEvaluation {
  name: string;
  checkpoints: ReplayCheckpoint[];
}
