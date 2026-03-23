import { buildHealthRows, buildRunDetailRows } from "../../src/state/projections";
import { BurnBarExtensionController } from "../../src/state/controller";

import type { ReplayEvaluation, ReplayScenario, ReplayStep } from "./types";

export async function evaluateReplayScenario(scenario: ReplayScenario): Promise<ReplayEvaluation> {
  const health = createSequenceResponder(scenario.daemon.health);
  const catalog = createSequenceResponder(scenario.daemon.catalog ?? []);
  const capabilities = createSequenceResponder(scenario.workspace.capabilities);
  const repair = createSequenceResponder(scenario.repair ? [scenario.repair] : []);

  const controller = new BurnBarExtensionController({
    client: {
      health: () => health(),
      catalog: () => catalog(),
      config: async () => ({ providers: [] }),
      recentUsage: async () => [],
      attach: async () => ({
        attachedClientID: "replay-client",
        negotiatedProtocolVersion: 1
      }),
      detach: async () => ({
        activeClientID: "replay-client",
        attachedClientIDs: ["replay-client"]
      }),
      createRun: async () => {
        throw new Error("Replay scenarios do not exercise run.create.");
      },
      listRuns: async () => [],
      getRun: async () => ({ run: null, approvalRequest: null, arbitration: null }),
      pollRuns: async () => ({
        runs: [],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "replay-client",
          attachedClientIDs: ["replay-client"]
        },
        emittedAt: new Date().toISOString()
      }),
      cancelRun: async () => ({ run: null, approvalRequest: null, arbitration: null }),
      retryRun: async () => ({ run: null, approvalRequest: null, arbitration: null }),
      executeTool: async () => ({ disposition: "no_pending_tool_call" }),
      submitToolResult: async () => ({ run: null, approvalRequest: null, arbitration: null }),
      respondToApproval: async () => ({ run: null, approvalRequest: null, arbitration: null })
    },
    workspaceClient: {
      capabilities: () => capabilities()
    },
    repairService: {
      repair: () => repair()
    }
  }, {
    clientID: "replay-client",
    sessionID: "replay-session"
  });

  const checkpoints: ReplayEvaluation["checkpoints"] = [];

  for (const action of scenario.actions) {
    if (action.type === "refresh") {
      await controller.refresh();
      checkpoints.push(captureCheckpoint(action.label, controller.snapshot));
      continue;
    }

    const result = await controller.repairDaemon();
    checkpoints.push(captureCheckpoint(action.label, controller.snapshot, result));
  }

  return {
    name: scenario.name,
    checkpoints
  };
}

function captureCheckpoint(
  label: string,
  snapshot: BurnBarExtensionController["snapshot"],
  actionResult?: { message: string }
): ReplayEvaluation["checkpoints"][number] {
  return {
    label,
    snapshot,
    healthRows: buildHealthRows(snapshot),
    runDetailRows: buildRunDetailRows(snapshot),
    actionResult
  };
}

function createSequenceResponder<T>(steps: ReplayStep<T>[]): () => Promise<T> {
  let index = 0;

  return async () => {
    const step = steps[Math.min(index, Math.max(steps.length - 1, 0))];
    index += 1;

    if (!step) {
      throw new Error("Replay fixture is missing a required sequence step.");
    }

    if ("error" in step) {
      throw new Error(step.error);
    }

    return step.result;
  };
}
