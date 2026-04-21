import { randomUUID } from 'node:crypto';

import type { OpenBurnBarDaemonClientLike } from '../daemon/client';
import type { OpenBurnBarRepairResult, OpenBurnBarRepairServiceLike } from '../daemon/repair';
import {
  BURNBAR_PROTOCOL_VERSION,
  type OpenBurnBarApprovalDecision,
  type OpenBurnBarApprovalRequest,
  type BurnBarCatalogModel,
  type BurnBarCatalogProvider,
  type BurnBarJSONValue,
  type BurnBarMissionMutationResponse,
  type BurnBarPendingQuestionSnapshot,
  type BurnBarQuestionAnswerResponse,
  type BurnBarRunCreateResponse,
  type BurnBarRunDetailResponse,
  type BurnBarRunPhase,
  type BurnBarRunProjection,
  type OpenBurnBarState,
  type BurnBarToolCallSnapshot,
  type BurnBarToolExecutionError,
  type BurnBarToolExecutionErrorCode,
  type BurnBarToolKind
} from '../types';
import type { OpenBurnBarWorkspaceRpcClientLike } from '../workspace/rpc';
import { OpenBurnBarWorkspaceRpcError } from '../workspace/types';
import {
  readFileResultToJSON,
  searchWorkspaceResultToJSON,
  applyPatchResultToJSON,
  runTerminalResultToJSON
} from '../workspace/conversion';
import { projectRuns } from './projections';

export interface OpenBurnBarControllerDependencies {
  client: OpenBurnBarDaemonClientLike;
  repairService: OpenBurnBarRepairServiceLike;
  workspaceClient: OpenBurnBarWorkspaceRpcClientLike;
}

export interface OpenBurnBarControllerOptions {
  clientID: string;
  sessionID?: string;
  clientName?: string;
  supportedProtocolVersions?: number[];
}

export interface BurnBarStartRunOptions {
  prompt: string;
  modelID: string;
  metadata?: Record<string, BurnBarJSONValue>;
}

class SimpleEventEmitter<T> {
  private listeners = new Set<(event: T) => void>();

  readonly event = (listener: (event: T) => void): { dispose(): void } => {
    this.listeners.add(listener);
    return {
      dispose: () => {
        this.listeners.delete(listener);
      }
    };
  };

  fire(event: T): void {
    for (const listener of this.listeners) {
      listener(event);
    }
  }

  dispose(): void {
    this.listeners.clear();
  }
}

export class OpenBurnBarExtensionController {
  private readonly eventEmitter = new SimpleEventEmitter<void>();
  private readonly clientID: string;
  private sessionID: string;
  private readonly clientName: string;
  private readonly supportedProtocolVersions: number[];
  private disposed = false;
  private toolLoopRunning = false;
  private toolLoopRequested = false;
  private refreshQueue: Promise<void> = Promise.resolve();
  private state: OpenBurnBarState = {
    connectionStatus: 'connecting',
    clientAttached: false,
    daemonRuns: [],
    pendingToolCalls: [],
    recentUsage: [],
    runs: []
  };

  constructor(
    private readonly dependencies: OpenBurnBarControllerDependencies,
    options: OpenBurnBarControllerOptions = { clientID: randomUUID() }
  ) {
    this.clientID = options.clientID;
    this.sessionID = options.sessionID ?? randomUUID();
    this.clientName = options.clientName ?? 'OpenBurnBar VS Code Extension';
    this.supportedProtocolVersions = options.supportedProtocolVersions ?? [BURNBAR_PROTOCOL_VERSION];

    this.state.runs = projectRuns(this.state);
    this.state.selectedRunId = chooseSelectedRunId(this.state.runs);
  }

  readonly onDidChangeState = this.eventEmitter.event;

  get snapshot(): OpenBurnBarState {
    return this.state;
  }

  get selectedRun() {
    return this.state.runs.find((run) => run.id === this.state.selectedRunId);
  }

  async initialize(): Promise<void> {
    await this.refresh();
  }

  async reconnect(): Promise<void> {
    this.sessionID = randomUUID();
    await this.refresh();
  }

  async refresh(): Promise<void> {
    const queuedRefresh = this.refreshQueue.catch(() => undefined).then(() => this.performRefresh());
    this.refreshQueue = queuedRefresh;
    await queuedRefresh;
  }

  private async performRefresh(): Promise<void> {
    this.patchState({
      connectionStatus: 'connecting',
      lastError: undefined,
      runError: undefined,
      workspaceError: undefined
    });

    try {
      const workspace = await this.dependencies.workspaceClient.capabilities();
      this.patchState({
        workspace,
        workspaceError: undefined
      });
    } catch (error) {
      this.patchState({
        workspace: undefined,
        workspaceError: error instanceof Error ? error.message : 'OpenBurnBar workspace companion is unavailable.'
      });
    }

    try {
      const health = await this.dependencies.client.health();
      let lastError: string | undefined;
      let runError: string | undefined;
      let clientAttached = false;
      let catalog = this.state.catalog;
      let daemonRuns = this.state.daemonRuns;
      let pendingToolCalls: typeof this.state.pendingToolCalls;
      let arbitration = this.state.arbitration;
      let recentUsage: typeof this.state.recentUsage;

      try {
        await this.attachClientSession();
        clientAttached = true;
      } catch (error) {
        lastError = error instanceof Error ? error.message : 'OpenBurnBar could not attach the sidebar session.';
        daemonRuns = [];
        pendingToolCalls = [];
      }

      try {
        catalog = await this.dependencies.client.catalog();
      } catch (error) {
        lastError ??= error instanceof Error ? error.message : 'Catalog request failed.';
      }

      if (clientAttached) {
        try {
          const polled = await this.withSessionRetry(() =>
            this.dependencies.client.pollRuns({
              clientID: this.clientID,
              sessionID: this.sessionID
            })
          );
          daemonRuns = polled.runs;
          pendingToolCalls = polled.pendingToolCalls;
          arbitration = polled.arbitration ?? undefined;
        } catch (error) {
          const message = error instanceof Error ? error.message : 'Run poll request failed.';
          if (message.includes('run.poll')) {
            daemonRuns = await this.withSessionRetry(() =>
              this.dependencies.client.listRuns({ clientID: this.clientID })
            );
            pendingToolCalls = [];
            arbitration = undefined;
          } else {
            runError = message;
            daemonRuns = [];
            pendingToolCalls = [];
          }
        }

        try {
          recentUsage = await this.dependencies.client.recentUsage(20);
        } catch {
          recentUsage = [];
        }
      } else {
        recentUsage = [];
        pendingToolCalls = [];
      }

      this.patchState({
        connectionStatus: 'connected',
        clientAttached,
        health,
        catalog,
        daemonRuns,
        pendingToolCalls,
        arbitration,
        selectedRunDetail: undefined,
        recentUsage,
        runError,
        lastError,
        lastUpdatedAt: new Date().toISOString()
      });

      await this.refreshSelectedRunDetail();
      this.requestToolLoop();
    } catch (error) {
      this.patchState({
        connectionStatus: 'disconnected',
        clientAttached: false,
        health: undefined,
        daemonRuns: [],
        pendingToolCalls: [],
        arbitration: undefined,
        selectedRunDetail: undefined,
        recentUsage: [],
        catalog: undefined,
        lastError: error instanceof Error ? error.message : 'Unable to reach the OpenBurnBar daemon.',
        runError: undefined,
        lastUpdatedAt: new Date().toISOString()
      });
    }
  }

  async repairDaemon(): Promise<OpenBurnBarRepairResult> {
    this.patchState({
      connectionStatus: 'repairing',
      clientAttached: false,
      lastError: undefined,
      runError: undefined
    });

    try {
      const result = await this.dependencies.repairService.repair();
      await this.refresh();
      return result;
    } catch (error) {
      this.patchState({
        connectionStatus: 'disconnected',
        clientAttached: false,
        lastError: error instanceof Error ? error.message : 'OpenBurnBar daemon repair failed.'
      });
      throw error;
    }
  }

  async selectRun(runId: string): Promise<void> {
    if (this.state.selectedRunId !== runId) {
      this.patchState({
        selectedRunId: runId,
        selectedRunDetail: undefined
      });
    }

    await this.refreshSelectedRunDetail(runId);
  }

  async getRunDetail(runId: string): Promise<BurnBarRunDetailResponse | undefined> {
    await this.ensureClientAttachment();

    const detail = await this.withSessionRetry(() =>
      this.dependencies.client.getRun({
        runID: runId,
        clientID: this.clientID
      })
    );

    const selectedRunId = this.state.selectedRunId === runId ? runId : this.state.selectedRunId;
    this.patchState({
      selectedRunId,
      selectedRunDetail: selectedRunId === runId ? detail : this.state.selectedRunDetail
    });

    return detail;
  }

  async startRun(options: BurnBarStartRunOptions): Promise<BurnBarRunCreateResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.createRun({
        clientID: this.clientID,
        sessionID: this.sessionID,
        prompt: options.prompt,
        modelID: options.modelID,
        metadata: options.metadata ?? {}
      })
    );

    await this.refresh();
    await this.selectRun(response.runID);
    return response;
  }

  async cancelRun(runId: string, reason = 'Cancelled from the OpenBurnBar sidebar.'): Promise<BurnBarRunDetailResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.cancelRun({
        runID: runId,
        clientID: this.clientID,
        reason
      })
    );

    await this.refresh();
    await this.selectRun(runId);
    return response;
  }

  async retryRun(runId: string): Promise<BurnBarRunDetailResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.retryRun({
        runID: runId,
        clientID: this.clientID
      })
    );

    await this.refresh();
    await this.selectRun(runId);
    return response;
  }

  async respondToApproval(
    runId: string,
    decision: OpenBurnBarApprovalDecision,
    note?: string
  ): Promise<BurnBarRunDetailResponse> {
    await this.ensureClientAttachment();
    const detail = await this.getRunDetail(runId);
    const approvalID = detail?.approvalRequest?.approvalID;

    if (!approvalID) {
      throw new Error(`Run '${runId}' does not have an active OpenBurnBar approval request.`);
    }

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.respondToApproval({
        response: {
          approvalID,
          clientID: this.clientID,
          decision,
          note,
          respondedAt: toBurnBarTimestamp()
        }
      })
    );

    await this.refresh();
    await this.selectRun(runId);
    return response;
  }

  // MARK: - Mission operator actions

  async approveMission(
    missionId: string,
    note?: string
  ): Promise<BurnBarMissionMutationResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.missionApprove({
        missionID: missionId,
        actor: this.clientID,
        note
      })
    );

    await this.refresh();
    return response;
  }

  async listMissions(projectSlug?: string): Promise<BurnBarMissionMutationResponse['mission'][]> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.missionList({ projectSlug })
    );

    return response.missions;
  }

  async getMission(missionId: string): Promise<BurnBarMissionMutationResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.missionGet({ missionID: missionId })
    );

    return response;
  }

  // MARK: - Question operator actions

  async answerPendingQuestion(
    questionId: string,
    answer: string,
    selectedOptionID?: string,
    markFollowupDone = true
  ): Promise<BurnBarQuestionAnswerResponse> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.questionAnswer({
        questionID: questionId,
        answeredBy: this.clientID,
        answer,
        selectedOptionID,
        markFollowupDone
      })
    );

    await this.refresh();
    return response;
  }

  async listPendingQuestions(projectSlug?: string): Promise<BurnBarPendingQuestionSnapshot[]> {
    await this.ensureClientAttachment();

    const response = await this.withControllerRetry(() =>
      this.dependencies.client.questionsList({ projectSlug, statuses: ['pending'] })
    );

    return response.questions;
  }

  availableModels(): Array<BurnBarCatalogModel & { provider: BurnBarCatalogProvider }> {
    return (
      this.state.catalog?.providers.flatMap((provider) =>
        provider.models
          .filter((model) => model.visibility === 'public')
          .map((model) => ({ ...model, provider }))
      ) ?? []
    );
  }

  activeRun(): BurnBarRunProjection | undefined {
    const activePhasesSet = new Set<BurnBarRunPhase>([
      'planning', 'awaiting_approval', 'executing_tool', 'waiting_on_companion', 'model_streaming'
    ]);
    return (
      this.state.runs.find((r) => activePhasesSet.has(r.phase)) ??
      this.state.runs.find((r) => r.id === this.state.selectedRunId) ??
      this.state.runs[0]
    );
  }

  historyRuns(): BurnBarRunProjection[] {
    const active = this.activeRun();
    if (!active) {
      return [];
    }
    return this.state.runs.filter((r) => r.id !== active.id);
  }

  approvalForRun(runId: string): OpenBurnBarApprovalRequest | undefined {
    const request = this.state.selectedRunDetail?.approvalRequest;
    return request?.runID === runId ? request : undefined;
  }

  workspaceCapabilitySummary(): { available: BurnBarToolKind[]; gated: BurnBarToolKind[]; trusted: boolean; hasWorkspace: boolean } {
    return {
      available: (this.state.workspace?.availableTools ?? []) as BurnBarToolKind[],
      gated: (this.state.workspace?.gatedTools ?? []) as BurnBarToolKind[],
      trusted: !this.state.workspace?.untrustedWorkspace,
      hasWorkspace: this.state.workspace?.hasWorkspace ?? false
    };
  }

  dispose(): void {
    this.disposed = true;

    if (this.state.clientAttached) {
      void this.dependencies.client
        .detach({
          clientID: this.clientID,
          sessionID: this.sessionID
        })
        .catch(() => undefined);
    }

    this.eventEmitter.dispose();
  }

  private async ensureClientAttachment(): Promise<void> {
    if (!this.state.clientAttached || this.state.connectionStatus !== 'connected') {
      await this.refresh();
    }

    if (!this.state.clientAttached) {
      throw new Error(this.state.lastError ?? 'OpenBurnBar is not attached to the local daemon.');
    }
  }

  private async attachClientSession(): Promise<void> {
    const response = await this.dependencies.client.attach({
      clientID: this.clientID,
      sessionID: this.sessionID,
      clientName: this.clientName,
      supportedProtocolVersions: this.supportedProtocolVersions
    });

    if (response.attachedClientID !== this.clientID) {
      throw new Error(`OpenBurnBar attached unexpected client '${response.attachedClientID}'.`);
    }

    if (response.negotiatedProtocolVersion !== BURNBAR_PROTOCOL_VERSION) {
      throw new Error(
        response.negotiatedProtocolVersion === null || response.negotiatedProtocolVersion === undefined
          ? 'OpenBurnBar could not negotiate a shared daemon protocol version.'
          : `OpenBurnBar protocol mismatch. Expected ${BURNBAR_PROTOCOL_VERSION}, negotiated ${response.negotiatedProtocolVersion}.`
      );
    }
  }

  private async withControllerRetry<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await this.withSessionRetry(operation);
    } catch (error) {
      if (!isObserverControlError(error)) {
        throw error;
      }

      const arbitration = await this.withSessionRetry(() =>
        this.dependencies.client.claimControl({
          clientID: this.clientID,
          sessionID: this.sessionID
        })
      );
      this.patchState({ arbitration });
      return await this.withSessionRetry(operation);
    }
  }

  private async withSessionRetry<T>(operation: () => Promise<T>): Promise<T> {
    try {
      return await operation();
    } catch (error) {
      if (!isSessionMismatchError(error)) {
        throw error;
      }

      await this.attachClientSession();
      this.patchState({
        clientAttached: true,
        lastError: undefined
      });
      return await operation();
    }
  }

  private async refreshSelectedRunDetail(runId = this.state.selectedRunId): Promise<void> {
    if (this.disposed || !runId) {
      return;
    }

    const run = this.state.runs.find((candidate) => candidate.id === runId);
    if (!run || run.source !== 'daemon' || !this.state.clientAttached) {
      if (this.state.selectedRunDetail) {
        this.patchState({
          selectedRunDetail: undefined
        });
      }
      return;
    }

    try {
      const detail = await this.withSessionRetry(() =>
        this.dependencies.client.getRun({
          runID: runId,
          clientID: this.clientID
        })
      );

      if (!this.disposed && this.state.selectedRunId === runId) {
        this.patchState({
          selectedRunDetail: detail
        });
      }
    } catch {
      if (!this.disposed && this.state.selectedRunId === runId) {
        this.patchState({
          selectedRunDetail: undefined
        });
      }
    }
  }

  private requestToolLoop(): void {
    if (this.disposed) {
      return;
    }

    if (this.toolLoopRunning) {
      this.toolLoopRequested = true;
      return;
    }

    void this.runToolLoop();
  }

  private async runToolLoop(): Promise<void> {
    if (this.toolLoopRunning) {
      return;
    }

    this.toolLoopRunning = true;
    try {
      do {
        this.toolLoopRequested = false;
        await this.processPendingToolCalls();
      } while (!this.disposed && this.toolLoopRequested);
    } finally {
      this.toolLoopRunning = false;
    }
  }

  private async processPendingToolCalls(): Promise<void> {
    if (this.disposed || !this.state.clientAttached || this.state.connectionStatus !== 'connected') {
      return;
    }

    if (this.state.pendingToolCalls.length === 0) {
      return;
    }

    const activeControllerID = this.state.arbitration?.activeClientID;
    if (activeControllerID && activeControllerID !== this.clientID) {
      return;
    }

    while (!this.disposed) {
      const claimed = await this.withControllerRetry(() =>
        this.dependencies.client.executeTool({
          clientID: this.clientID,
          sessionID: this.sessionID
        })
      );

      if (claimed.disposition !== 'dispatched' || !claimed.toolCall) {
        return;
      }

      const submission = await this.executeWorkspaceTool(claimed.toolCall);
      await this.withControllerRetry(() =>
        this.dependencies.client.submitToolResult({
          clientID: this.clientID,
          sessionID: this.sessionID,
          ...submission
        })
      );
      await this.refreshPolledRuns();
    }
  }

  private async refreshPolledRuns(): Promise<void> {
    try {
      const polled = await this.withSessionRetry(() =>
        this.dependencies.client.pollRuns({
          clientID: this.clientID,
          sessionID: this.sessionID
        })
      );

      this.patchState({
        daemonRuns: polled.runs,
        pendingToolCalls: polled.pendingToolCalls,
        arbitration: polled.arbitration ?? undefined,
        runError: undefined,
        lastUpdatedAt: polled.emittedAt
      });

      await this.refreshSelectedRunDetail();
    } catch (error) {
      this.patchState({
        runError: error instanceof Error ? error.message : 'Run poll request failed.'
      });
    }
  }

  private async executeWorkspaceTool(toolCall: BurnBarToolCallSnapshot): Promise<{
    runID: string;
    callID: string;
    succeeded: boolean;
    output?: BurnBarJSONValue | null;
    error?: BurnBarToolExecutionError;
    completedAt: number;
  }> {
    const completedAt = toBurnBarTimestamp();

    try {
      const output = await this.invokeWorkspaceTool(toolCall);
      return {
        runID: toolCall.runID,
        callID: toolCall.callID,
        succeeded: true,
        output,
        completedAt
      };
    } catch (error) {
      return {
        runID: toolCall.runID,
        callID: toolCall.callID,
        succeeded: false,
        error: mapToolError(error, toolCall.tool),
        completedAt
      };
    }
  }

  private async invokeWorkspaceTool(toolCall: BurnBarToolCallSnapshot): Promise<BurnBarJSONValue> {
    const args = expectObject(toolCall.arguments, `tool call ${toolCall.callID} arguments`);
    const workspaceClient = this.dependencies.workspaceClient;

    switch (toolCall.tool) {
    case 'read_file': {
      const path = expectString(args.path, 'read_file.path');
      if (!workspaceClient.readFile) {
        throw new Error('Workspace RPC client does not support read_file.');
      }
      const result = await workspaceClient.readFile({ path });
      return readFileResultToJSON(result);
    }
    case 'search_workspace': {
      const query = expectString(args.query, 'search_workspace.query');
      if (!workspaceClient.searchWorkspace) {
        throw new Error('Workspace RPC client does not support search_workspace.');
      }
      const result = await workspaceClient.searchWorkspace({
        query,
        include: optionalString(args.include),
        exclude: optionalString(args.exclude),
        maxResults: optionalNumber(args.maxResults),
        maxFiles: optionalNumber(args.maxFiles),
        maxFileBytes: optionalNumber(args.maxFileBytes),
        caseSensitive: optionalBoolean(args.caseSensitive)
      });
      return searchWorkspaceResultToJSON(result);
    }
    case 'apply_patch': {
      const changes = expectArray(args.changes, 'apply_patch.changes');
      if (!workspaceClient.applyPatch) {
        throw new Error('Workspace RPC client does not support apply_patch.');
      }
      const result = await workspaceClient.applyPatch({
        changes: changes.map((change, index) => {
          const object = expectObject(change, `apply_patch.changes[${index}]`);
          return {
            path: expectString(object.path, `apply_patch.changes[${index}].path`),
            text: expectString(object.text, `apply_patch.changes[${index}].text`),
            range: object.range
              ? toRange(expectObject(object.range, `apply_patch.changes[${index}].range`))
              : undefined
          };
        })
      });
      return applyPatchResultToJSON(result);
    }
    case 'run_terminal': {
      const command = expectString(args.command, 'run_terminal.command');
      if (!workspaceClient.runTerminal) {
        throw new Error('Workspace RPC client does not support run_terminal.');
      }
      const result = await workspaceClient.runTerminal({
        command,
        cwd: optionalString(args.cwd),
        name: optionalString(args.name),
        preserveFocus: optionalBoolean(args.preserveFocus)
      });
      return runTerminalResultToJSON(result);
    }
    default: {
      throw new Error(`Unknown workspace tool: ${(toolCall as { tool: string }).tool}`);
    }
    }
  }

  private patchState(partial: Partial<OpenBurnBarState>): void {
    const nextState: OpenBurnBarState = {
      ...this.state,
      ...partial
    };

    nextState.runs = projectRuns(nextState);
    nextState.selectedRunId = chooseSelectedRunId(nextState.runs, partial.selectedRunId ?? this.state.selectedRunId);
    if (
      nextState.selectedRunDetail?.run?.runID &&
      nextState.selectedRunDetail.run.runID !== nextState.selectedRunId
    ) {
      nextState.selectedRunDetail = undefined;
    }

    this.state = nextState;
    this.eventEmitter.fire();
  }
}

function toBurnBarTimestamp(date = new Date()): number {
  return date.getTime() / 1000 - 978_307_200;
}

function isObserverControlError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  const message = error.message.toLowerCase();
  return message.includes('attached as an observer') && message.includes('cannot control runs');
}

function isSessionMismatchError(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  return error.message.toLowerCase().includes('client session mismatch');
}

function chooseSelectedRunId(runs: OpenBurnBarState['runs'], currentSelectedRunId?: string): string | undefined {
  if (currentSelectedRunId && runs.some((run) => run.id === currentSelectedRunId)) {
    return currentSelectedRunId;
  }

  return runs[0]?.id;
}

function mapToolError(error: unknown, tool: BurnBarToolKind): BurnBarToolExecutionError {
  const message = error instanceof Error ? error.message : 'Workspace companion failed to execute the requested tool.';
  const workspaceCode = error instanceof OpenBurnBarWorkspaceRpcError ? error.code : undefined;
  let code: BurnBarToolExecutionErrorCode;

  switch (workspaceCode) {
  case 'TRUST_REQUIRED':
    code = 'trust_gated';
    break;
  case 'NO_WORKSPACE':
    code = 'no_workspace';
    break;
  case 'PATH_OUTSIDE_WORKSPACE':
    code = tool === 'run_terminal' ? 'terminal_failed' : 'apply_failed';
    break;
  case 'VIRTUAL_WORKSPACE':
  case 'REMOTE_UNSUPPORTED':
    code = 'remote_unsupported';
    break;
  case 'APPLY_EDIT_FAILED':
  case 'SAVE_FAILED':
  case 'READONLY_WORKSPACE':
    code = 'apply_failed';
    break;
  default:
    if (tool === 'run_terminal') {
      code = 'terminal_failed';
    } else if (tool === 'apply_patch') {
      code = 'apply_failed';
    } else {
      code = 'unknown';
    }
  }

  return { code, message };
}

function expectObject(
  value: BurnBarJSONValue,
  label: string
): Record<string, BurnBarJSONValue> {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, BurnBarJSONValue>;
  }
  throw new Error(`Expected ${label} to be an object.`);
}

function expectArray(value: BurnBarJSONValue | undefined, label: string): BurnBarJSONValue[] {
  if (Array.isArray(value)) {
    return value;
  }
  throw new Error(`Expected ${label} to be an array.`);
}

function expectString(value: BurnBarJSONValue | undefined, label: string): string {
  if (typeof value === 'string') {
    return value;
  }
  throw new Error(`Expected ${label} to be a string.`);
}

function optionalString(value: BurnBarJSONValue | undefined): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function optionalNumber(value: BurnBarJSONValue | undefined): number | undefined {
  return typeof value === 'number' ? value : undefined;
}

function optionalBoolean(value: BurnBarJSONValue | undefined): boolean | undefined {
  return typeof value === 'boolean' ? value : undefined;
}

function toRange(range: Record<string, BurnBarJSONValue>): {
  start: { line: number; character: number };
  end: { line: number; character: number };
} {
  const start = expectObject(range.start as BurnBarJSONValue, 'range.start');
  const end = expectObject(range.end as BurnBarJSONValue, 'range.end');

  return {
    start: {
      line: expectNumber(start.line, 'range.start.line'),
      character: expectNumber(start.character, 'range.start.character')
    },
    end: {
      line: expectNumber(end.line, 'range.end.line'),
      character: expectNumber(end.character, 'range.end.character')
    }
  };
}

function expectNumber(value: BurnBarJSONValue | undefined, label: string): number {
  if (typeof value === 'number') {
    return value;
  }
  throw new Error(`Expected ${label} to be a number.`);
}
