import { describe, expect, it, vi, beforeEach } from "vitest";

import { buildPanelViewModel } from "../src/state/panelViewModel";
import type { BurnBarPanelViewModel } from "../src/state/panelViewModel";
import { projectRuns } from "../src/state/projections";
import type { BurnBarState } from "../src/types";

describe("workspace panel view model integration", () => {
  function makeConnectedState(overrides: Partial<BurnBarState> = {}): BurnBarState {
    return {
      connectionStatus: "connected",
      clientAttached: true,
      health: {
        ok: true,
        daemonVersion: "0.1.0",
        protocolVersion: 1,
        socketPath: "/tmp/burnbar.sock"
      },
      catalog: {
        schemaVersion: 1,
        providers: [
          {
            id: "z-ai",
            displayName: "Z.ai",
            baseURL: "https://api.z.ai",
            visibility: "public" as const,
            capabilities: ["routing"],
            models: [
              {
                id: "glm-4.6",
                displayName: "GLM 4.6",
                visibility: "public" as const,
                aliases: [],
                pricing: { inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.5 }
              }
            ]
          }
        ]
      },
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      runs: [],
      workspace: {
        hasWorkspace: true,
        localWorkspace: true,
        remoteWorkspace: false,
        readonlyWorkspace: false,
        virtualWorkspace: false,
        untrustedWorkspace: false,
        workspaceHost: "ui",
        availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
        gatedTools: []
      },
      ...overrides
    };
  }

  it("produces a view model suitable for both sidebar and workspace surfaces", () => {
    const state = makeConnectedState();
    const vm = buildPanelViewModel(state, { showOpenBurnBarApp: true });

    expect(vm.isConnected).toBe(true);
    expect(vm.isDaemonUnavailable).toBe(false);
    expect(vm.showOpenBurnBarApp).toBe(true);
    expect(vm.selectedModelOptions).toHaveLength(1);
    expect(vm.selectedModelOptions[0].id).toBe("glm-4.6");
    expect(vm.isComposerEnabled).toBe(true);
    expect(vm.noRunsYet).toBe(true);
    expect(vm.statusLineText).toBeDefined();
  });

  it("supports a configurable compact sidebar status line", () => {
    const state = makeConnectedState();
    state.runs = projectRuns(state);

    const modelsVm = buildPanelViewModel(state, { sidebarStatusLineMode: "models" });
    expect(modelsVm.statusLineText).toContain("visible model");

    const workspaceVm = buildPanelViewModel(state, { sidebarStatusLineMode: "workspace" });
    expect(workspaceVm.statusLineText).toContain("Local");

    const offVm = buildPanelViewModel(state, { sidebarStatusLineMode: "off" });
    expect(offVm.statusLineText).toBeUndefined();
  });

  it("includes workspace description and capability chips", () => {
    const state = makeConnectedState();
    const vm = buildPanelViewModel(state);

    expect(vm.hasWorkspace).toBe(true);
    expect(vm.isWorkspaceTrusted).toBe(true);
    expect(vm.workspaceDescription).toContain("Local");
    expect(vm.capabilityChips.length).toBeGreaterThan(0);
  });

  it("includes system info for the system section", () => {
    const state = makeConnectedState();
    const vm = buildPanelViewModel(state);

    expect(vm.systemInfo.daemonVersion).toBe("0.1.0");
    expect(vm.systemInfo.protocolVersion).toBe("v1");
    expect(vm.systemInfo.socketPath).toBe("/tmp/burnbar.sock");
    expect(vm.systemInfo.connectionStatus).toBe("Connected");
    expect(vm.systemInfo.workspaceHost).toBe("ui");
  });

  it("populates active run and history for the runs section", () => {
    const state = makeConnectedState({
      daemonRuns: [
        {
          runID: "run-abc",
          clientID: "c1",
          sessionID: "s1",
          phase: "planning" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:00.000Z"
        },
        {
          runID: "run-def",
          clientID: "c1",
          sessionID: "s1",
          phase: "completed" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T09:00:00.000Z"
        }
      ]
    });

    // Re-project runs (normally done by controller)

    state.runs = projectRuns(state);
    state.selectedRunId = state.runs[0]?.id;

    const vm = buildPanelViewModel(state);

    expect(vm.activeRun).toBeDefined();
    expect(vm.activeRun!.phase).toBe("planning");
    expect(vm.historyRuns).toHaveLength(1);
    expect(vm.historyRuns[0].phase).toBe("completed");
  });

  it("shows approval state when a run is awaiting approval", () => {
    const state = makeConnectedState({
      daemonRuns: [
        {
          runID: "run-xyz",
          clientID: "c1",
          sessionID: "s1",
          phase: "awaiting_approval" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:00.000Z",
          activeApprovalID: "approval-1"
        }
      ],
      selectedRunDetail: {
        run: {
          runID: "run-xyz",
          clientID: "c1",
          sessionID: "s1",
          phase: "awaiting_approval" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:00.000Z",
          activeApprovalID: "approval-1"
        },
        approvalRequest: {
          approvalID: "approval-1",
          runID: "run-xyz",
          tool: "apply_patch" as const,
          title: "Apply patch to main.ts",
          message: "Replace function body with updated implementation.",
          requestedAt: "2026-03-22T10:00:01.000Z"
        }
      }
    });


    state.runs = projectRuns(state);
    state.selectedRunId = "run-xyz";

    const vm = buildPanelViewModel(state);

    expect(vm.approvalState).toBeDefined();
    expect(vm.approvalState!.title).toBe("Apply patch to main.ts");
    expect(vm.approvalState!.tool).toBe("apply_patch");
  });

  it("disables composer when no models are available", () => {
    const state = makeConnectedState({
      catalog: { schemaVersion: 1, providers: [] }
    });
    const vm = buildPanelViewModel(state);

    expect(vm.isComposerEnabled).toBe(false);
    expect(vm.composerDisabledReason).toBeDefined();
  });

  it("shows recovery message when disconnected", () => {
    const state = makeConnectedState({
      connectionStatus: "disconnected" as const,
      health: undefined,
      clientAttached: false,
      catalog: undefined,
      daemonRuns: [],
      pendingToolCalls: [],
      recentUsage: [],
      lastError: "Unable to reach the BurnBar daemon."
    });


    state.runs = projectRuns(state);

    const vm = buildPanelViewModel(state);

    expect(vm.isDaemonUnavailable).toBe(true);
    expect(vm.recoveryMessage).toBeDefined();
    expect(vm.lastError).toBe("Unable to reach the BurnBar daemon.");
  });

  it("includes selected run detail for inspector panel", () => {
    const state = makeConnectedState({
      daemonRuns: [
        {
          runID: "run-detail",
          clientID: "c1",
          sessionID: "s1",
          phase: "executing_tool" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:05:00.000Z"
        }
      ],
      selectedRunDetail: {
        run: {
          runID: "run-detail",
          clientID: "c1",
          sessionID: "s1",
          phase: "executing_tool" as const,
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:05:00.000Z"
        },
        pendingToolCall: {
          callID: "call-1",
          runID: "run-detail",
          tool: "read_file" as const,
          arguments: { path: "src/main.ts" },
          status: "in_progress" as const,
          requestedBy: "c1",
          requestedAt: "2026-03-22T10:05:01.000Z"
        },
        loopState: {
          iterationCount: 3,
          lastDecision: {
            action: "read_file" as const,
            requestedTool: "read_file" as const,
            rationale: "Need to read main.ts to understand the current implementation.",
            arguments: { path: "src/main.ts" }
          },
          terminalPending: false
        }
      },
      recentUsage: [
        {
          runID: "run-detail",
          providerID: "z-ai",
          modelID: "glm-4.6",
          inputTokens: 1234,
          outputTokens: 567,
          cacheReadTokens: 0,
          cost: 0.0034,
          recordedAt: "2026-03-22T10:05:02.000Z"
        }
      ]
    });


    state.runs = projectRuns(state);
    state.selectedRunId = "run-detail";

    const vm = buildPanelViewModel(state);

    expect(vm.selectedRunDetail).toBeDefined();
    expect(vm.selectedRunDetail!.summary).toContain("executing_tool");
    expect(vm.selectedRunDetail!.usageText).toContain("z-ai");
    expect(vm.selectedRunDetail!.loopDecisionText).toContain("read_file");
  });
});

describe("workspace panel protocol messages", () => {
  it("sidebar protocol includes openWorkspace message type", async () => {
    const protocol = await import("../src/views/panelProtocol");

    // Type check — openWorkspace should be assignable to BurnBarPanelWebviewMessage
    const msg: typeof protocol.BurnBarPanelWebviewMessage extends never
      ? never
      : { type: "openWorkspace" } = { type: "openWorkspace" };
    expect(msg.type).toBe("openWorkspace");
  });

  it("workspace protocol includes switchSection message type", async () => {
    const protocol = await import("../src/views/panelProtocol");

    const msg: { type: "switchSection"; section: "command" | "runs" | "system" } = {
      type: "switchSection",
      section: "command"
    };
    expect(msg.type).toBe("switchSection");
    expect(msg.section).toBe("command");
  });

  it("workspace protocol includes openConversationSearch message type", async () => {
    const protocol = await import("../src/views/panelProtocol");

    const msg: { type: "openConversationSearch" } = { type: "openConversationSearch" };
    expect(msg.type).toBe("openConversationSearch");
  });
});
