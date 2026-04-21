import { describe, expect, it, vi } from "vitest";

import { buildHealthRows, buildRunDetailRows } from "../src/state/projections";
import { OpenBurnBarExtensionController } from "../src/state/controller";
import { buildPanelViewModel } from "../src/state/panelViewModel";
import { OpenBurnBarWorkspaceRpcError } from "../src/workspace/types";

function makeConnectedClient(overrides: Partial<ConstructorParameters<typeof OpenBurnBarExtensionController>[0]["client"]> = {}) {
  return {
    health: vi.fn().mockResolvedValue({
      ok: true,
      daemonVersion: "0.1.0",
      protocolVersion: 1,
      socketPath: "/tmp/openburnbar.sock"
    }),
    catalog: vi.fn().mockResolvedValue({
      schemaVersion: 1,
      providers: [
        {
          id: "z-ai",
          displayName: "Z.ai",
          baseURL: "https://api.z.ai",
          visibility: "public",
          capabilities: ["routing"],
          models: [
            {
              id: "glm-4.6",
              displayName: "GLM 4.6",
              visibility: "public",
              aliases: [],
              pricing: {
                inputPerMToken: 1,
                outputPerMToken: 2,
                cacheReadPerMToken: 0.5
              }
            }
          ]
        }
      ]
    }),
    config: vi.fn().mockResolvedValue({
      providers: []
    }),
    recentUsage: vi.fn().mockResolvedValue([]),
    attach: vi.fn().mockResolvedValue({
      attachedClientID: "test-client",
      negotiatedProtocolVersion: 1
    }),
    claimControl: vi.fn().mockResolvedValue({
      activeClientID: "test-client",
      attachedClientIDs: ["other-client", "test-client"],
      reason: "controller_transferred_to_requesting_client"
    }),
    detach: vi.fn().mockResolvedValue({
      activeClientID: "test-client",
      attachedClientIDs: ["test-client"],
      reason: "controller_detached"
    }),
    createRun: vi.fn(),
    listRuns: vi.fn().mockResolvedValue([
      {
        runID: "run-1234",
        clientID: "test-client",
        sessionID: "session-1",
        phase: "awaiting_approval",
        modelID: "glm-4.6",
        updatedAt: "2026-03-22T10:00:00.000Z",
        activeApprovalID: "approval-1"
      }
    ]),
    pollRuns: vi.fn().mockResolvedValue({
      runs: [
        {
          runID: "run-1234",
          clientID: "test-client",
          sessionID: "session-1",
          phase: "awaiting_approval",
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:00.000Z",
          activeApprovalID: "approval-1"
        }
      ],
      approvals: [
        {
          approvalID: "approval-1",
          runID: "run-1234",
          tool: "apply_patch",
          title: "Approve apply_patch",
          message: "OpenBurnBar needs approval before continuing this simulated tool step.",
          requestedAt: "2026-03-22T10:00:00.000Z"
        }
      ],
      pendingToolCalls: [],
      arbitration: {
        activeClientID: "test-client",
        attachedClientIDs: ["test-client"],
        reason: "first_controller_attached"
      },
      emittedAt: "2026-03-22T10:00:00.000Z"
    }),
    getRun: vi.fn().mockResolvedValue({
      run: {
        runID: "run-1234",
        clientID: "test-client",
        sessionID: "session-1",
        phase: "awaiting_approval",
        modelID: "glm-4.6",
        updatedAt: "2026-03-22T10:00:00.000Z",
        activeApprovalID: "approval-1"
      },
      approvalRequest: {
        approvalID: "approval-1",
        runID: "run-1234",
        tool: "apply_patch",
        title: "Approve apply_patch",
        message: "OpenBurnBar needs approval before continuing this simulated tool step.",
        requestedAt: "2026-03-22T10:00:00.000Z"
      },
      arbitration: {
        activeClientID: "test-client",
        attachedClientIDs: ["test-client"],
        reason: "first_controller_attached"
      }
    }),
    executeTool: vi.fn().mockResolvedValue({
      disposition: "no_pending_tool_call"
    }),
    submitToolResult: vi.fn().mockResolvedValue({
      run: null,
      approvalRequest: null,
      arbitration: null
    }),
    cancelRun: vi.fn().mockResolvedValue({
      run: {
        runID: "run-1234",
        clientID: "test-client",
        sessionID: "session-1",
        phase: "cancelled",
        modelID: "glm-4.6",
        updatedAt: "2026-03-22T10:01:00.000Z",
        errorMessage: "Cancelled by controller."
      }
    }),
    retryRun: vi.fn().mockResolvedValue({
      run: {
        runID: "run-1234",
        clientID: "test-client",
        sessionID: "session-1",
        phase: "completed",
        modelID: "glm-4.6",
        updatedAt: "2026-03-22T10:02:00.000Z"
      }
    }),
    respondToApproval: vi.fn().mockResolvedValue({
      run: {
        runID: "run-1234",
        clientID: "test-client",
        sessionID: "session-1",
        phase: "completed",
        modelID: "glm-4.6",
        updatedAt: "2026-03-22T10:03:00.000Z"
      }
    }),
    missionApprove: vi.fn(),
    missionList: vi.fn().mockResolvedValue({ missions: [] }),
    missionGet: vi.fn(),
    questionAnswer: vi.fn(),
    questionsList: vi.fn().mockResolvedValue({ questions: [] }),
    controllerSummary: vi.fn().mockResolvedValue({
      summary: {
        activeProjectSlug: "test-project",
        counts: {
          projectCount: 1,
          pendingQuestionCount: 0,
          openFollowupCount: 0,
          activeMissionCount: 0,
          staleProjectCount: 0
        },
        freshness: "provisional",
        needsOperatorAttention: false,
        metadata: {}
      }
    }),
    ...overrides
  };
}

const localWorkspaceCapabilities = {
  hasWorkspace: true,
  localWorkspace: true,
  remoteWorkspace: false,
  readonlyWorkspace: false,
  virtualWorkspace: false,
  untrustedWorkspace: false,
  workspaceHost: "ui" as const,
  availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
  gatedTools: [],
  explanation: "Workspace tools are running in the local extension host. All workspace tools are available."
};

describe("OpenBurnBarExtensionController", () => {
  it("loads daemon-backed runs after attaching the OpenBurnBar client session", async () => {
    const client = makeConnectedClient();
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();

    expect(client.attach).toHaveBeenCalledWith(
      expect.objectContaining({
        clientID: "test-client",
        sessionID: "session-1"
      })
    );
    expect(controller.snapshot.connectionStatus).toBe("connected");
    expect(controller.snapshot.clientAttached).toBe(true);
    expect(controller.snapshot.runs.map((run) => run.id)).toEqual(["run-1234"]);
    expect(controller.snapshot.selectedRunId).toBe("run-1234");
    expect(controller.snapshot.selectedRunDetail?.approvalRequest?.approvalID).toBe("approval-1");
    expect(buildRunDetailRows(controller.snapshot)).toContainEqual(
      expect.objectContaining({
        id: "approval-tool",
        value: "apply_patch"
      })
    );
  });

  it("VAL-EXT-001: daemon-unavailable state surfaces actionable reconnect/repair recovery guidance", async () => {
    const controller = new OpenBurnBarExtensionController(
      {
        client: {
          ...makeConnectedClient(),
          health: vi.fn().mockRejectedValue(new Error("socket missing"))
        },
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: true,
            localWorkspace: false,
            remoteWorkspace: true,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: true,
            workspaceHost: "workspace",
            availableTools: ["read_file", "search_workspace"],
            gatedTools: ["apply_patch", "run_terminal"],
            explanation:
              "Workspace tools are running on the remote workspace host. This workspace is in restricted mode, so OpenBurnBar will not apply patches or run terminal commands until you trust it."
          })
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client"
      }
    );

    await controller.refresh();

    expect(controller.snapshot.connectionStatus).toBe("disconnected");
    expect(controller.snapshot.runs[0]).toMatchObject({
      id: "daemon-unavailable",
      phase: "failed"
    });
    expect(controller.snapshot.lastError).toContain("socket missing");
    expect(controller.snapshot.runs[0]?.note).toContain("Repair Daemon");
    expect(controller.snapshot.workspace?.gatedTools).toEqual(["apply_patch", "run_terminal"]);

    expect(buildHealthRows(controller.snapshot)).toContainEqual(
      expect.objectContaining({
        id: "next-step",
        value: expect.stringContaining("Repair Daemon")
      })
    );
    expect(buildRunDetailRows(controller.snapshot)).toContainEqual(
      expect.objectContaining({
        id: "recovery",
        value: expect.stringContaining("Repair Daemon")
      })
    );

    const vm = buildPanelViewModel(controller.snapshot);
    expect(vm.recoveryMessage).toContain("Reconnect");
    expect(vm.recoveryMessage).toContain("Repair Daemon");
  });

  it("runs repair and refreshes daemon-backed state", async () => {
    const client = makeConnectedClient({
      health: vi
        .fn()
        .mockRejectedValueOnce(new Error("socket missing"))
        .mockResolvedValue({
          ok: true,
          daemonVersion: "0.1.0",
          protocolVersion: 1,
          socketPath: "/tmp/openburnbar.sock"
        })
    });
    const repair = vi.fn().mockResolvedValue({
      message: "OpenBurnBar daemon restart requested."
    });
    const capabilities = vi.fn().mockResolvedValue(localWorkspaceCapabilities);

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: { capabilities },
        repairService: { repair }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    const result = await controller.repairDaemon();

    expect(repair).toHaveBeenCalledTimes(1);
    expect(result.message).toContain("restart requested");
    expect(controller.snapshot.connectionStatus).toBe("connected");
    expect(controller.snapshot.runs[0]?.source).toBe("daemon");
    expect(capabilities).toHaveBeenCalledTimes(2);
  });

  it("VAL-EXT-002: reattaches and retries when a run RPC hits a session mismatch", async () => {
    const client = makeConnectedClient({
      createRun: vi
        .fn()
        .mockRejectedValueOnce(
          new Error(
            "Client session mismatch. Expected 'old-session', received 'session-1'."
          )
        )
        .mockResolvedValue({
          runID: "run-new",
          phase: "awaiting_approval"
        })
    });

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    const result = await controller.startRun({
      prompt: "Search for BurnBarRunService",
      modelID: "glm-4.6"
    });

    expect(result.runID).toBe("run-new");
    expect(client.createRun).toHaveBeenCalledTimes(2);
    expect(client.attach).toHaveBeenCalledTimes(3);
    expect(controller.snapshot.connectionStatus).toBe("connected");
    expect(controller.snapshot.clientAttached).toBe(true);
    expect(controller.snapshot.lastError).toBeUndefined();
  });

  it("VAL-EXT-002: refresh auto-recovers poll session mismatch via deterministic reattach-and-retry", async () => {
    const client = makeConnectedClient({
      pollRuns: vi
        .fn()
        .mockRejectedValueOnce(
          new Error(
            "Client session mismatch. Expected 'old-session', received 'session-1'."
          )
        )
        .mockResolvedValue({
          runs: [
            {
              runID: "run-1234",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "awaiting_approval",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:00.000Z",
              activeApprovalID: "approval-1"
            }
          ],
          approvals: [
            {
              approvalID: "approval-1",
              runID: "run-1234",
              tool: "apply_patch",
              title: "Approve apply_patch",
              message: "OpenBurnBar needs approval before continuing this simulated tool step.",
              requestedAt: "2026-03-22T10:00:00.000Z"
            }
          ],
          pendingToolCalls: [],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"],
            reason: "controller_reconnected"
          },
          emittedAt: "2026-03-22T10:00:00.000Z"
        })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();

    expect(client.pollRuns).toHaveBeenCalledTimes(2);
    expect(client.attach).toHaveBeenCalledTimes(2);
    expect(controller.snapshot.connectionStatus).toBe("connected");
    expect(controller.snapshot.clientAttached).toBe(true);
    expect(controller.snapshot.lastError).toBeUndefined();
    expect(controller.snapshot.runs[0]?.id).toBe("run-1234");
  });

  it("surfaces a no-workspace empty state without claiming tools are ready", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: false,
            localWorkspace: false,
            remoteWorkspace: false,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "ui",
            availableTools: [],
            gatedTools: [],
            explanation: "Open a workspace folder to enable OpenBurnBar file, search, edit, and terminal tools."
          })
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client"
      }
    );

    await controller.refresh();

    expect(controller.snapshot.runs[0]).toMatchObject({
      id: "empty-run-list",
      title: "No runs yet",
      phase: "idle"
    });
    expect(buildHealthRows(controller.snapshot)).toContainEqual(
      expect.objectContaining({
        id: "workspace-mode",
        value: "No workspace open • ui host"
      })
    );
    expect(buildHealthRows(controller.snapshot)).toContainEqual(
      expect.objectContaining({
        id: "workspace-tools",
        value: "Open a folder or workspace to enable OpenBurnBar tools."
      })
    );
  });

  it("starts and approves a run through the daemon RPC methods", async () => {
    const client = makeConnectedClient({
      createRun: vi.fn().mockResolvedValue({
        runID: "run-new",
        phase: "awaiting_approval"
      }),
      listRuns: vi
        .fn()
        .mockResolvedValueOnce([
          {
            runID: "run-1234",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "awaiting_approval",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:00:00.000Z",
            activeApprovalID: "approval-1"
          }
        ])
        .mockResolvedValue([
          {
            runID: "run-new",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "completed",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:03:00.000Z"
          }
        ]),
      getRun: vi.fn().mockImplementation(async ({ runID }: { runID: string }) => {
        if (runID === "run-1234") {
          return {
            run: {
              runID: "run-1234",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "awaiting_approval",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:00.000Z",
              activeApprovalID: "approval-1"
            },
            approvalRequest: {
              approvalID: "approval-1",
              runID: "run-1234",
              tool: "apply_patch",
              title: "Approve apply_patch",
              message: "OpenBurnBar needs approval before continuing this simulated tool step.",
              requestedAt: "2026-03-22T10:00:00.000Z"
            }
          };
        }

        return {
          run: {
            runID: "run-new",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "completed",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:03:00.000Z"
          }
        };
      }),
      respondToApproval: vi.fn().mockResolvedValue({
        run: {
          runID: "run-new",
          clientID: "test-client",
          sessionID: "session-1",
          phase: "completed",
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:03:00.000Z"
        }
      })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    await controller.startRun({
      prompt: "Need approval",
      modelID: "glm-4.6"
    });
    await controller.respondToApproval("run-1234", "approve");

    expect(client.createRun).toHaveBeenCalledWith(
      expect.objectContaining({
        clientID: "test-client",
        sessionID: "session-1",
        prompt: "Need approval",
        modelID: "glm-4.6"
      })
    );
    expect(client.respondToApproval).toHaveBeenCalledWith(
      expect.objectContaining({
        response: expect.objectContaining({
          approvalID: "approval-1",
          clientID: "test-client",
          decision: "approve"
        })
      })
    );
  });

  it("VAL-CROSS-003 / VAL-EXT-005: explicit approve clears approval object and resumes high-risk run", async () => {
    let runPhase: "awaiting_approval" | "planning" = "awaiting_approval";
    let hasApproval = true;

    const runSnapshot = () => ({
      runID: "run-high-risk",
      clientID: "test-client",
      sessionID: "session-1",
      phase: runPhase,
      modelID: "glm-4.6",
      updatedAt: "2026-03-22T10:00:00.000Z",
      activeApprovalID: hasApproval ? "approval-high-risk" : undefined
    });
    const approvalSnapshot = () => ({
      approvalID: "approval-high-risk",
      runID: "run-high-risk",
      tool: "run_terminal",
      title: "Approve run_terminal",
      message: "High-risk terminal command requires explicit approval.",
      requestedAt: "2026-03-22T10:00:00.000Z"
    });

    const client = makeConnectedClient({
      listRuns: vi.fn().mockImplementation(async () => [runSnapshot()]),
      pollRuns: vi.fn().mockImplementation(async () => ({
        runs: [runSnapshot()],
        approvals: hasApproval ? [approvalSnapshot()] : [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      })),
      getRun: vi.fn().mockImplementation(async () => ({
        run: runSnapshot(),
        approvalRequest: hasApproval ? approvalSnapshot() : undefined,
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        }
      })),
      respondToApproval: vi.fn().mockImplementation(async ({ response }: { response: { decision: string } }) => {
        if (response.decision === "approve") {
          runPhase = "planning";
        }
        hasApproval = false;
        return {
          run: runSnapshot(),
          approvalRequest: undefined
        };
      })
    });

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    expect(controller.snapshot.selectedRunDetail?.approvalRequest?.approvalID).toBe("approval-high-risk");

    await controller.respondToApproval("run-high-risk", "approve");

    expect(client.respondToApproval).toHaveBeenCalledWith(
      expect.objectContaining({
        response: expect.objectContaining({
          approvalID: "approval-high-risk",
          decision: "approve"
        })
      })
    );
    expect(controller.snapshot.selectedRunDetail?.approvalRequest).toBeUndefined();
    expect(controller.snapshot.runs.find((run) => run.id === "run-high-risk")?.phase).toBe("planning");
  });

  it("VAL-EXT-005: explicit reject clears approval object and transitions run to cancelled", async () => {
    let runPhase: "awaiting_approval" | "cancelled" = "awaiting_approval";
    let hasApproval = true;

    const runSnapshot = () => ({
      runID: "run-reject",
      clientID: "test-client",
      sessionID: "session-1",
      phase: runPhase,
      modelID: "glm-4.6",
      updatedAt: "2026-03-22T10:00:00.000Z",
      activeApprovalID: hasApproval ? "approval-reject" : undefined
    });
    const approvalSnapshot = () => ({
      approvalID: "approval-reject",
      runID: "run-reject",
      tool: "apply_patch",
      title: "Approve apply_patch",
      message: "Apply patch requires explicit approval.",
      requestedAt: "2026-03-22T10:00:00.000Z"
    });

    const client = makeConnectedClient({
      listRuns: vi.fn().mockImplementation(async () => [runSnapshot()]),
      pollRuns: vi.fn().mockImplementation(async () => ({
        runs: [runSnapshot()],
        approvals: hasApproval ? [approvalSnapshot()] : [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      })),
      getRun: vi.fn().mockImplementation(async () => ({
        run: runSnapshot(),
        approvalRequest: hasApproval ? approvalSnapshot() : undefined,
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        }
      })),
      respondToApproval: vi.fn().mockImplementation(async () => {
        runPhase = "cancelled";
        hasApproval = false;
        return {
          run: runSnapshot(),
          approvalRequest: undefined
        };
      })
    });

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    expect(controller.snapshot.selectedRunDetail?.approvalRequest?.approvalID).toBe("approval-reject");

    await controller.respondToApproval("run-reject", "reject");

    expect(client.respondToApproval).toHaveBeenCalledWith(
      expect.objectContaining({
        response: expect.objectContaining({
          approvalID: "approval-reject",
          decision: "reject"
        })
      })
    );
    expect(controller.snapshot.selectedRunDetail?.approvalRequest).toBeUndefined();
    expect(controller.snapshot.runs.find((run) => run.id === "run-reject")?.phase).toBe("cancelled");
  });

  it("dispatches pending tool calls to the workspace companion and submits results", async () => {
    const readToolCall = {
      callID: "call-read-1",
      runID: "run-workflow",
      tool: "read_file" as const,
      arguments: { path: "src/example.ts" },
      status: "pending" as const,
      requestedBy: "test-client",
      requestedAt: "2026-03-22T10:00:00.000Z"
    };
    const client = makeConnectedClient({
      pollRuns: vi
        .fn()
        .mockResolvedValueOnce({
          runs: [
            {
              runID: "run-workflow",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "waiting_on_companion",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:00.000Z"
            }
          ],
          approvals: [],
          pendingToolCalls: [readToolCall],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          },
          emittedAt: "2026-03-22T10:00:00.000Z"
        })
        .mockResolvedValue({
          runs: [
            {
              runID: "run-workflow",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "completed",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:01.000Z"
            }
          ],
          approvals: [],
          pendingToolCalls: [],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          },
          emittedAt: "2026-03-22T10:00:01.000Z"
        }),
      executeTool: vi
        .fn()
        .mockResolvedValueOnce({
          disposition: "dispatched",
          toolCall: readToolCall
        })
        .mockResolvedValue({
          disposition: "no_pending_tool_call"
        }),
      submitToolResult: vi.fn().mockResolvedValue({
        run: {
          runID: "run-workflow",
          clientID: "test-client",
          sessionID: "session-1",
          phase: "completed",
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:01.000Z"
        }
      })
    });
    const readFile = vi.fn().mockResolvedValue({
      path: "file:///workspace/src/example.ts",
      content: "export const value = 1;\n"
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities),
          readFile
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(readFile).toHaveBeenCalledWith({ path: "src/example.ts" });
    expect(client.submitToolResult).toHaveBeenCalledWith(
      expect.objectContaining({
        runID: "run-workflow",
        callID: "call-read-1",
        succeeded: true
      })
    );
  });

  it("VAL-EXT-003: observer-only mutation rejection claims control once and retries deterministically", async () => {
    const createRun = vi
      .fn()
      .mockRejectedValueOnce(new Error("Client 'test-client' is attached as an observer and cannot control runs."))
      .mockResolvedValue({
        runID: "run-claimed",
        phase: "planning"
      });
    const claimControl = vi.fn().mockResolvedValue({
      activeClientID: "test-client",
      attachedClientIDs: ["other-client", "test-client"],
      reason: "controller_transferred_to_requesting_client"
    });
    const client = makeConnectedClient({
      createRun,
      claimControl,
      pollRuns: vi
        .fn()
        .mockResolvedValueOnce({
          runs: [],
          approvals: [],
          pendingToolCalls: [],
          arbitration: {
            activeClientID: "other-client",
            attachedClientIDs: ["other-client", "test-client"],
            reason: "observer_attached_controller_retained"
          },
          emittedAt: "2026-03-22T10:00:00.000Z"
        })
        .mockResolvedValue({
          runs: [
            {
              runID: "run-claimed",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "planning",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:01.000Z"
            }
          ],
          approvals: [],
          pendingToolCalls: [],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["other-client", "test-client"],
            reason: "controller_transferred_to_requesting_client"
          },
          emittedAt: "2026-03-22T10:00:01.000Z"
        })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    await controller.startRun({
      prompt: "Need control",
      modelID: "glm-4.6"
    });

    expect(claimControl).toHaveBeenCalledWith({
      clientID: "test-client",
      sessionID: "session-1"
    });
    expect(claimControl).toHaveBeenCalledTimes(1);
    expect(createRun).toHaveBeenCalledTimes(2);
  });

  it("VAL-EXT-003: observer mutation errors with claim-control guidance also trigger claim-and-retry", async () => {
    const createRun = vi
      .fn()
      .mockRejectedValueOnce(
        new Error("Observer client cannot mutate mission state; claim control and retry.")
      )
      .mockResolvedValue({
        runID: "run-claimed-variant",
        phase: "planning"
      });
    const claimControl = vi.fn().mockResolvedValue({
      activeClientID: "test-client",
      attachedClientIDs: ["other-client", "test-client"],
      reason: "controller_transferred_to_requesting_client"
    });
    const client = makeConnectedClient({
      createRun,
      claimControl
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    const created = await controller.startRun({
      prompt: "Need control",
      modelID: "glm-4.6"
    });

    expect(created.runID).toBe("run-claimed-variant");
    expect(claimControl).toHaveBeenCalledTimes(1);
    expect(createRun).toHaveBeenCalledTimes(2);
  });

  it("maps trust-gated workspace refusals into structured daemon tool errors", async () => {
    const patchToolCall = {
      callID: "call-patch-1",
      runID: "run-workflow",
      tool: "apply_patch" as const,
      arguments: {
        changes: [
          {
            path: "src/example.ts",
            text: "export const value = 2;\n"
          }
        ]
      },
      status: "pending" as const,
      requestedBy: "test-client",
      requestedAt: "2026-03-22T10:00:00.000Z"
    };
    const client = makeConnectedClient({
      pollRuns: vi
        .fn()
        .mockResolvedValueOnce({
          runs: [
            {
              runID: "run-workflow",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "waiting_on_companion",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:00.000Z"
            }
          ],
          approvals: [],
          pendingToolCalls: [patchToolCall],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          },
          emittedAt: "2026-03-22T10:00:00.000Z"
        })
        .mockResolvedValue({
          runs: [
            {
              runID: "run-workflow",
              clientID: "test-client",
              sessionID: "session-1",
              phase: "awaiting_approval",
              modelID: "glm-4.6",
              updatedAt: "2026-03-22T10:00:01.000Z",
              activeApprovalID: "approval-workflow"
            }
          ],
          approvals: [
            {
              approvalID: "approval-workflow",
              runID: "run-workflow",
              tool: "apply_patch",
              title: "Workspace action required",
              message: "Trust this workspace before applying edits.",
              requestedAt: "2026-03-22T10:00:01.000Z"
            }
          ],
          pendingToolCalls: [],
          arbitration: {
            activeClientID: "test-client",
            attachedClientIDs: ["test-client"]
          },
          emittedAt: "2026-03-22T10:00:01.000Z"
        }),
      executeTool: vi
        .fn()
        .mockResolvedValueOnce({
          disposition: "dispatched",
          toolCall: patchToolCall
        })
        .mockResolvedValue({
          disposition: "no_pending_tool_call"
        }),
      submitToolResult: vi.fn().mockResolvedValue({
        run: {
          runID: "run-workflow",
          clientID: "test-client",
          sessionID: "session-1",
          phase: "awaiting_approval",
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:00:01.000Z"
        }
      })
    });
    const applyPatch = vi
      .fn()
      .mockRejectedValue(new OpenBurnBarWorkspaceRpcError("TRUST_REQUIRED", "Trust this workspace before applying edits."));
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities),
          applyPatch
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(client.submitToolResult).toHaveBeenCalledWith(
      expect.objectContaining({
        runID: "run-workflow",
        callID: "call-patch-1",
        succeeded: false,
        error: expect.objectContaining({
          code: "trust_gated"
        })
      })
    );
  });

  it("projects pending tool labels on run cards", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [
          {
            runID: "run-tooling",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "waiting_on_companion",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:00:00.000Z"
          }
        ],
        approvals: [],
        pendingToolCalls: [
          {
            callID: "call-read-1",
            runID: "run-tooling",
            tool: "read_file",
            arguments: { path: "src/example.ts" },
            status: "pending",
            requestedBy: "test-client",
            requestedAt: "2026-03-22T10:00:00.000Z"
          }
        ],
        arbitration: {
          activeClientID: "other-client",
          attachedClientIDs: ["other-client", "test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      }),
      executeTool: vi.fn().mockResolvedValue({
        disposition: "no_pending_tool_call"
      })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();

    expect(controller.snapshot.runs[0]).toMatchObject({
      id: "run-tooling",
      note: "Reading file"
    });
  });
});

describe("buildPanelViewModel", () => {
  it("produces no-workspace state without capability chips", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: false,
            localWorkspace: false,
            remoteWorkspace: false,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "ui" as const,
            availableTools: [],
            gatedTools: [],
            explanation: "Open a workspace folder to enable OpenBurnBar file, search, edit, and terminal tools."
          })
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.hasWorkspace).toBe(false);
    expect(vm.workspaceDescription).toBe("No workspace open");
    expect(vm.capabilityChips).toEqual([
      { label: "Open a folder to enable tools", kind: "warning" }
    ]);
    expect(vm.noRunsYet).toBe(true);
    expect(vm.isConnected).toBe(true);
    expect(vm.showOpenBurnBarApp).toBe(false);
  });

  it("respects showOpenBurnBarApp host flag", async () => {
    const client = makeConnectedClient();
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client" }
    );

    await controller.refresh();
    expect(buildPanelViewModel(controller.snapshot).showOpenBurnBarApp).toBe(false);
    expect(
      buildPanelViewModel(controller.snapshot, { showOpenBurnBarApp: true }).showOpenBurnBarApp
    ).toBe(true);
  });

  it("VAL-EXT-001: produces daemon-unavailable panel state with explicit recovery messaging", async () => {
    const controller = new OpenBurnBarExtensionController(
      {
        client: {
          ...makeConnectedClient(),
          health: vi.fn().mockRejectedValue(new Error("socket missing"))
        },
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue({
            hasWorkspace: true,
            localWorkspace: true,
            remoteWorkspace: false,
            readonlyWorkspace: false,
            virtualWorkspace: false,
            untrustedWorkspace: false,
            workspaceHost: "ui" as const,
            availableTools: ["read_file", "search_workspace", "apply_patch", "run_terminal"],
            gatedTools: [],
            explanation: "All tools available."
          })
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.isDaemonUnavailable).toBe(true);
    expect(vm.isConnected).toBe(false);
    expect(vm.recoveryMessage).toContain("socket missing");
    expect(vm.recoveryMessage).toContain("Reconnect");
    expect(vm.recoveryMessage).toContain("Repair Daemon");
    expect(vm.isComposerEnabled).toBe(false);
    expect(vm.activeRun?.phase).toBe("failed");
  });

  it("surfaces approval state on the selected run", async () => {
    const client = makeConnectedClient();
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client", sessionID: "session-1" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.approvalState).toBeDefined();
    expect(vm.approvalState?.tool).toBe("apply_patch");
    expect(vm.approvalState?.title).toContain("apply_patch");
    expect(vm.activeRun?.phaseColor).toBe("warning");
    expect(vm.activeRun?.hasApproval).toBe(true);
  });

  it("surfaces loop rationale and final response text on the selected run", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [
          {
            runID: "run-loop",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "completed",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:04:00.000Z"
          }
        ],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:04:00.000Z"
      }),
      getRun: vi.fn().mockResolvedValue({
        run: {
          runID: "run-loop",
          clientID: "test-client",
          sessionID: "session-1",
          phase: "completed",
          modelID: "glm-4.6",
          updatedAt: "2026-03-22T10:04:00.000Z"
        },
        approvalRequest: null,
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"],
          reason: "first_controller_attached"
        },
        loopState: {
          iterationCount: 3,
          lastDecision: {
            action: "complete",
            rationale: "Enough evidence gathered to answer confidently.",
            message: "OpenBurnBar found the right file and finished the edit."
          },
          lastContextSnapshot: {
            candidatePaths: ["src/state/controller.ts"],
            searchHints: ["controller"],
            searchResultPaths: ["src/state/controller.ts"]
          },
          lastExecutedTool: "apply_patch",
          terminalPending: false
        }
      })
    });

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client", sessionID: "session-1" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.selectedRunDetail?.responseText).toContain("finished the edit");
    expect(vm.selectedRunDetail?.loopDecisionText).toContain("Enough evidence gathered");
  });

  it("places active runs first and completed runs in history", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [
          {
            runID: "run-active",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "model_streaming",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:01:00.000Z"
          },
          {
            runID: "run-done",
            clientID: "test-client",
            sessionID: "session-1",
            phase: "completed",
            modelID: "glm-4.6",
            updatedAt: "2026-03-22T10:00:00.000Z"
          }
        ],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:01:00.000Z"
      }),
      getRun: vi.fn().mockResolvedValue({ run: null, approvalRequest: null, arbitration: null })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client", sessionID: "session-1" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.activeRun?.id).toBe("run-active");
    expect(vm.activeRun?.phaseColor).toBe("active");
    expect(vm.historyRuns).toHaveLength(1);
    expect(vm.historyRuns[0]?.id).toBe("run-done");
    expect(vm.historyRuns[0]?.phaseColor).toBe("success");
  });

  it("populates model options from catalog public models", async () => {
    const client = makeConnectedClient({
      pollRuns: vi.fn().mockResolvedValue({
        runs: [],
        approvals: [],
        pendingToolCalls: [],
        arbitration: {
          activeClientID: "test-client",
          attachedClientIDs: ["test-client"]
        },
        emittedAt: "2026-03-22T10:00:00.000Z"
      })
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client" }
    );

    await controller.refresh();
    const vm = buildPanelViewModel(controller.snapshot);

    expect(vm.isComposerEnabled).toBe(true);
    expect(vm.selectedModelOptions).toHaveLength(1);
    expect(vm.selectedModelOptions[0]?.id).toBe("glm-4.6");
    expect(vm.selectedModelOptions[0]?.providerName).toBe("Z.ai");
  });

  // MARK: - VAL-EXT-004: Pending tool lifecycle is end-to-end visible

  it("VAL-EXT-004: pending tool lifecycle is end-to-end visible through poll transitions", async () => {
    // VAL-EXT-004: run.poll pending call, dispatch, and completion transitions are reflected in extension state.
    // This test verifies the full pending tool lifecycle: waiting -> in-progress -> completed.

    let pollCallCount = 0;
    const pendingToolCall = {
      toolCallID: "tool-call-1",
      runID: "run-pending-tool",
      toolName: "search_files",
      arguments: { query: "BurnBarRun" },
      status: "waiting" as const,
      createdAt: "2026-03-22T09:00:00.000Z"
    };

    const client = makeConnectedClient({
      pollRuns: vi.fn().mockImplementation(() => {
        pollCallCount++;
        // Simulate phase transitions over poll cycles
        if (pollCallCount === 1) {
          return Promise.resolve({
            runs: [
              {
                runID: "run-pending-tool",
                clientID: "test-client",
                sessionID: "session-1",
                phase: "executing_tool",
                modelID: "glm-4.6",
                updatedAt: "2026-03-22T09:00:00.000Z"
              }
            ],
            approvals: [],
            pendingToolCalls: [pendingToolCall],
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T09:00:00.000Z"
          });
        } else if (pollCallCount === 2) {
          return Promise.resolve({
            runs: [
              {
                runID: "run-pending-tool",
                clientID: "test-client",
                sessionID: "session-1",
                phase: "model_streaming",
                modelID: "glm-4.6",
                updatedAt: "2026-03-22T09:00:05.000Z"
              }
            ],
            approvals: [],
            pendingToolCalls: [], // Tool completed
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T09:00:05.000Z"
          });
        } else {
          return Promise.resolve({
            runs: [
              {
                runID: "run-pending-tool",
                clientID: "test-client",
                sessionID: "session-1",
                phase: "completed",
                modelID: "glm-4.6",
                updatedAt: "2026-03-22T09:00:10.000Z"
              }
            ],
            approvals: [],
            pendingToolCalls: [],
            arbitration: {
              activeClientID: "test-client",
              attachedClientIDs: ["test-client"]
            },
            emittedAt: "2026-03-22T09:00:10.000Z"
          });
        }
      })
    });

    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: { repair: vi.fn().mockResolvedValue({ message: "ok" }) }
      },
      { clientID: "test-client", sessionID: "session-1" }
    );

    // Initial poll: pending tool visible
    await controller.refresh();
    expect(controller.snapshot.runs[0]?.phase).toBe("executing_tool");
    expect(controller.snapshot.pendingToolCalls).toHaveLength(1);
    expect(controller.snapshot.pendingToolCalls[0]?.toolName).toBe("search_files");
    expect(controller.snapshot.pendingToolCalls[0]?.status).toBe("waiting");

    // Second poll: tool dispatch in progress (removed from pending)
    await controller.refresh();
    expect(controller.snapshot.pendingToolCalls).toHaveLength(0);
    expect(controller.snapshot.runs[0]?.phase).toBe("model_streaming");

    // Third poll: run completed
    await controller.refresh();
    expect(controller.snapshot.runs[0]?.phase).toBe("completed");
    expect(controller.snapshot.pendingToolCalls).toHaveLength(0);
  });
});

describe("VAL-EXT-009: Mission operator actions", () => {
  it("VAL-EXT-009: approveMission calls daemon missionApprove and refreshes state", async () => {
    const missionApprove = vi.fn().mockResolvedValue({
      mission: {
        id: "mission-1",
        projectSlug: "test-project",
        title: "Test Mission",
        summary: "A test mission",
        status: "approved",
        recommendation: "proceed",
        createdAt: "2026-03-22T10:00:00.000Z",
        updatedAt: "2026-03-22T10:05:00.000Z",
        approval: {
          approved: true,
          approvedAt: "2026-03-22T10:05:00.000Z",
          approvedBy: "test-client"
        },
        packets: [],
        results: [],
        burnRecords: [],
        takeoverHistory: [],
        metadata: {}
      }
    });
    const client = makeConnectedClient({
      missionApprove
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    const result = await controller.approveMission("mission-1", "Approved from extension");

    expect(missionApprove).toHaveBeenCalledWith({
      missionID: "mission-1",
      actor: "test-client",
      note: "Approved from extension"
    });
    expect(result.mission.status).toBe("approved");
    expect(result.mission.approval?.approved).toBe(true);
  });

  it("VAL-EXT-009: answerPendingQuestion calls daemon questionAnswer and refreshes state", async () => {
    const questionAnswer = vi.fn().mockResolvedValue({
      question: {
        id: "question-1",
        projectSlug: "test-project",
        title: "What should happen next?",
        prompt: "Need operator input",
        stageLabel: "Operator Decision",
        status: "answered",
        priority: "normal",
        askedAt: "2026-03-22T10:00:00.000Z",
        latestAnswer: {
          answer: "Proceed with the plan",
          answeredBy: "test-client",
          answeredAt: "2026-03-22T10:05:00.000Z"
        },
        evidenceRefs: [],
        suggestedOptions: [
          {
            id: "proceed",
            title: "Proceed",
            detail: "Keep the current direction",
            answer: "Proceed with the plan"
          }
        ],
        metadata: {}
      }
    });
    const client = makeConnectedClient({
      questionAnswer
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();
    const result = await controller.answerPendingQuestion(
      "question-1",
      "Proceed with the plan",
      "proceed",
      true
    );

    expect(questionAnswer).toHaveBeenCalledWith({
      questionID: "question-1",
      answeredBy: "test-client",
      answer: "Proceed with the plan",
      selectedOptionID: "proceed",
      markFollowupDone: true
    });
    expect(result.question.status).toBe("answered");
    expect(result.question.latestAnswer?.answer).toBe("Proceed with the plan");
  });

  it("VAL-EXT-009: mission approve action mutates daemon state and converges without manual refresh", async () => {
    // Track whether mission has been approved
    let missionApproved = false;

    const missionApprove = vi.fn().mockImplementation(() => {
      missionApproved = true;
      return Promise.resolve({
        mission: {
          id: "mission-awaiting",
          projectSlug: "test-project",
          title: "Awaiting Approval",
          summary: "Needs approval",
          status: "approved",
          recommendation: "proceed",
          createdAt: "2026-03-22T10:00:00.000Z",
          updatedAt: "2026-03-22T10:05:00.000Z",
          approval: {
            approved: true,
            approvedAt: "2026-03-22T10:05:00.000Z",
            approvedBy: "test-client"
          },
          packets: [],
          results: [],
          burnRecords: [],
          takeoverHistory: [],
          metadata: {}
        }
      });
    });

    const missionList = vi.fn().mockImplementation(() => {
      return Promise.resolve({
        missions: [
          {
            id: "mission-awaiting",
            projectSlug: "test-project",
            title: "Awaiting Approval",
            summary: "Needs approval",
            status: missionApproved ? "approved" : "awaiting_approval",
            recommendation: "review",
            createdAt: "2026-03-22T10:00:00.000Z",
            updatedAt: missionApproved ? "2026-03-22T10:05:00.000Z" : "2026-03-22T10:00:00.000Z",
            approval: missionApproved
              ? { approved: true, approvedAt: "2026-03-22T10:05:00.000Z", approvedBy: "test-client" }
              : { approved: false },
            packets: [],
            results: [],
            burnRecords: [],
            takeoverHistory: [],
            metadata: {}
          }
        ]
      });
    });

    const client = makeConnectedClient({
      missionApprove,
      missionList
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();

    // Initial state: mission is awaiting_approval
    const missionsBefore = await controller.listMissions();
    expect(missionsBefore[0]?.status).toBe("awaiting_approval");
    expect(missionsBefore[0]?.approval?.approved).toBe(false);

    // Approve the mission via daemon RPC
    await controller.approveMission("mission-awaiting", "Approved via extension");

    // After approval: mission status is updated and converged
    const missionsAfter = await controller.listMissions();
    expect(missionsAfter[0]?.status).toBe("approved");
    expect(missionsAfter[0]?.approval?.approved).toBe(true);
    expect(missionApprove).toHaveBeenCalledWith({
      missionID: "mission-awaiting",
      actor: "test-client",
      note: "Approved via extension"
    });
  });

  it("VAL-EXT-009: question answer action mutates daemon state and converges without manual refresh", async () => {
    // Track whether question has been answered
    let questionAnswered = false;

    const questionAnswer = vi.fn().mockImplementation(() => {
      questionAnswered = true;
      return Promise.resolve({
        question: {
          id: "pending-question",
          projectSlug: "test-project",
          title: "What should happen?",
          prompt: "Need a decision",
          stageLabel: "Operator Decision",
          status: "answered",
          priority: "normal",
          askedAt: "2026-03-22T10:00:00.000Z",
          latestAnswer: {
            answer: "Proceed",
            answeredBy: "test-client",
            answeredAt: "2026-03-22T10:05:00.000Z"
          },
          evidenceRefs: [],
          suggestedOptions: [],
          metadata: {}
        }
      });
    });

    const questionsList = vi.fn().mockImplementation(() => {
      return Promise.resolve({
        questions: [
          {
            id: "pending-question",
            projectSlug: "test-project",
            title: "What should happen?",
            prompt: "Need a decision",
            stageLabel: "Operator Decision",
            status: questionAnswered ? "answered" : "pending",
            priority: "normal",
            askedAt: "2026-03-22T10:00:00.000Z",
            latestAnswer: questionAnswered
              ? { answer: "Proceed", answeredBy: "test-client", answeredAt: "2026-03-22T10:05:00.000Z" }
              : undefined,
            evidenceRefs: [],
            suggestedOptions: [],
            metadata: {}
          }
        ]
      });
    });

    const client = makeConnectedClient({
      questionAnswer,
      questionsList
    });
    const controller = new OpenBurnBarExtensionController(
      {
        client,
        workspaceClient: {
          capabilities: vi.fn().mockResolvedValue(localWorkspaceCapabilities)
        },
        repairService: {
          repair: vi.fn().mockResolvedValue({
            message: "OpenBurnBar daemon restart requested."
          })
        }
      },
      {
        clientID: "test-client",
        sessionID: "session-1"
      }
    );

    await controller.refresh();

    // Initial state: question is pending
    const questionsBefore = await controller.listPendingQuestions();
    expect(questionsBefore[0]?.status).toBe("pending");
    expect(questionsBefore[0]?.latestAnswer).toBeUndefined();

    // Answer the question via daemon RPC
    await controller.answerPendingQuestion("pending-question", "Proceed", undefined, true);

    // After answer: question state is updated and converged
    const questionsAfter = await controller.listPendingQuestions();
    expect(questionsAfter[0]?.status).toBe("answered");
    expect(questionsAfter[0]?.latestAnswer?.answer).toBe("Proceed");
    expect(questionAnswer).toHaveBeenCalledWith({
      questionID: "pending-question",
      answeredBy: "test-client",
      answer: "Proceed",
      selectedOptionID: undefined,
      markFollowupDone: true
    });
  });
});
