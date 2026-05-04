import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { createConnection } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';

import {
  BURNBAR_PROTOCOL_VERSION,
  type BurnBarCatalog,
  type BurnBarCatalogResponse,
  type BurnBarClientArbitrationSnapshot,
  type BurnBarClientAttachRequest,
  type BurnBarClientAttachResponse,
  type BurnBarClientClaimControlRequest,
  type BurnBarClientDetachRequest,
  type BurnBarConfigResponse,
  type BurnBarHealthResponse,
  type BurnBarRecentUsageRequest,
  type BurnBarRecentUsageResponse,
  type BurnBarRPCRequestEnvelopeWithParams,
  type BurnBarRPCMethod,
  type BurnBarRPCRequestEnvelope,
  type BurnBarRPCResponseEnvelope,
  type BurnBarSearchQueryDaemonResult,
  type BurnBarSearchQueryParams
} from '../types';
import type {
  OpenBurnBarApprovalRespondRequest,
  BurnBarRunCancelRequest,
  BurnBarRunCreateRequest,
  BurnBarRunCreateResponse,
  BurnBarRunDetailResponse,
  BurnBarRunEventBatch,
  BurnBarRunGetRequest,
  BurnBarRunListRequest,
  BurnBarRunListResponse,
  BurnBarRunPollRequest,
  BurnBarRunRetryRequest
} from '../types';
import type {
  BurnBarToolExecutionRequest,
  BurnBarToolExecutionResponse,
  BurnBarToolResultSubmissionRequest
} from '../types';
import type {
  BurnBarMissionApproveRequest,
  BurnBarMissionMutationResponse,
  BurnBarMissionListRequest,
  BurnBarMissionListResponse,
  BurnBarMissionGetRequest,
  BurnBarQuestionAnswerRequest,
  BurnBarQuestionAnswerResponse,
  BurnBarQuestionsListRequest,
  BurnBarQuestionsListResponse,
  BurnBarControllerSummaryResponse
} from '../types';

export const DEFAULT_BURNBAR_SOCKET_PATH = join(
  homedir(),
  'Library',
  'Application Support',
  'OpenBurnBar',
  'openburnbar-daemon.sock'
);
export const DEFAULT_BURNBAR_LAUNCH_AGENT_PLIST = join(
  homedir(),
  'Library',
  'LaunchAgents',
  'com.openburnbar.daemon.plist'
);
const DEFAULT_MAX_IN_FLIGHT = 8;

function resolveDefaultSocketPath(): string {
  return (
    process.env.OPENBURNBAR_DAEMON_SOCKET_PATH ??
    process.env.BURNBAR_DAEMON_SOCKET_PATH ??
    DEFAULT_BURNBAR_SOCKET_PATH
  );
}

function resolveDefaultAuthToken(): string | undefined {
  const envToken = process.env.OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN ?? process.env.BURNBAR_DAEMON_SOCKET_AUTH_TOKEN;
  if (envToken?.trim()) {
    return envToken.trim();
  }

  try {
    const plist = readFileSync(DEFAULT_BURNBAR_LAUNCH_AGENT_PLIST, 'utf8');
    const match = plist.match(/<key>OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN<\/key>\s*<string>([^<]+)<\/string>/);
    return match?.[1]?.trim() || undefined;
  } catch {
    return undefined;
  }
}

export interface OpenBurnBarDaemonClientOptions {
  socketPath?: string;
  timeoutMs?: number;
  authToken?: string;
  maxInFlight?: number;
}

export class OpenBurnBarDaemonClientError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OpenBurnBarDaemonClientError';
  }
}

export interface OpenBurnBarDaemonClientLike {
  health(): Promise<BurnBarHealthResponse>;
  catalog(): Promise<BurnBarCatalog>;
  config(): Promise<BurnBarConfigResponse['snapshot']>;
  recentUsage(limit?: number): Promise<BurnBarRecentUsageResponse['usage']>;
  attach(params: BurnBarClientAttachRequest): Promise<BurnBarClientAttachResponse>;
  claimControl(params: BurnBarClientClaimControlRequest): Promise<BurnBarClientArbitrationSnapshot>;
  detach(params: BurnBarClientDetachRequest): Promise<BurnBarClientArbitrationSnapshot>;
  createRun(params: BurnBarRunCreateRequest): Promise<BurnBarRunCreateResponse>;
  listRuns(params: BurnBarRunListRequest): Promise<BurnBarRunListResponse['runs']>;
  getRun(params: BurnBarRunGetRequest): Promise<BurnBarRunDetailResponse>;
  pollRuns(params: BurnBarRunPollRequest): Promise<BurnBarRunEventBatch>;
  cancelRun(params: BurnBarRunCancelRequest): Promise<BurnBarRunDetailResponse>;
  retryRun(params: BurnBarRunRetryRequest): Promise<BurnBarRunDetailResponse>;
  executeTool(params: BurnBarToolExecutionRequest): Promise<BurnBarToolExecutionResponse>;
  submitToolResult(params: BurnBarToolResultSubmissionRequest): Promise<BurnBarRunDetailResponse>;
  respondToApproval(params: OpenBurnBarApprovalRespondRequest): Promise<BurnBarRunDetailResponse>;
  searchQuery(params: BurnBarSearchQueryParams): Promise<BurnBarSearchQueryDaemonResult>;
  // Mission methods
  missionApprove(params: BurnBarMissionApproveRequest): Promise<BurnBarMissionMutationResponse>;
  missionList(params: BurnBarMissionListRequest): Promise<BurnBarMissionListResponse>;
  missionGet(params: BurnBarMissionGetRequest): Promise<BurnBarMissionMutationResponse>;
  // Question methods
  questionAnswer(params: BurnBarQuestionAnswerRequest): Promise<BurnBarQuestionAnswerResponse>;
  questionsList(params: BurnBarQuestionsListRequest): Promise<BurnBarQuestionsListResponse>;
  // Controller methods
  controllerSummary(): Promise<BurnBarControllerSummaryResponse>;
}

export class OpenBurnBarDaemonClient implements OpenBurnBarDaemonClientLike {
  private readonly socketPath: string;
  private readonly timeoutMs: number;
  private readonly authToken?: string;
  private readonly maxInFlight: number;
  private inFlight = 0;

  constructor(options: OpenBurnBarDaemonClientOptions = {}) {
    this.socketPath = options.socketPath ?? resolveDefaultSocketPath();
    this.timeoutMs = options.timeoutMs ?? 60_000;
    this.authToken = options.authToken?.trim() || resolveDefaultAuthToken();
    this.maxInFlight = options.maxInFlight ?? DEFAULT_MAX_IN_FLIGHT;
  }

  async health(): Promise<BurnBarHealthResponse> {
    return this.send<BurnBarHealthResponse>('daemon.health');
  }

  async catalog(): Promise<BurnBarCatalog> {
    const response = await this.send<BurnBarCatalogResponse>('daemon.catalog');
    return response.catalog;
  }

  async config(): Promise<BurnBarConfigResponse['snapshot']> {
    const response = await this.send<BurnBarConfigResponse, Record<string, never>>('daemon.config.get', {});
    return response.snapshot;
  }

  async recentUsage(limit = 20): Promise<BurnBarRecentUsageResponse['usage']> {
    const response = await this.send<BurnBarRecentUsageResponse, BurnBarRecentUsageRequest>('daemon.usage.recent', {
      limit
    });
    return response.usage;
  }

  async attach(params: BurnBarClientAttachRequest): Promise<BurnBarClientAttachResponse> {
    return this.send('client.attach', params);
  }

  async claimControl(params: BurnBarClientClaimControlRequest): Promise<BurnBarClientArbitrationSnapshot> {
    return this.send('client.claimControl', params);
  }

  async detach(params: BurnBarClientDetachRequest): Promise<BurnBarClientArbitrationSnapshot> {
    return this.send('client.detach', params);
  }

  async createRun(params: BurnBarRunCreateRequest): Promise<BurnBarRunCreateResponse> {
    return this.send('run.create', params);
  }

  async listRuns(params: BurnBarRunListRequest): Promise<BurnBarRunListResponse['runs']> {
    const response = await this.send<BurnBarRunListResponse, BurnBarRunListRequest>('run.list', params);
    return response.runs;
  }

  async getRun(params: BurnBarRunGetRequest): Promise<BurnBarRunDetailResponse> {
    return this.send('run.get', params);
  }

  async pollRuns(params: BurnBarRunPollRequest): Promise<BurnBarRunEventBatch> {
    return this.send('run.poll', params);
  }

  async cancelRun(params: BurnBarRunCancelRequest): Promise<BurnBarRunDetailResponse> {
    return this.send('run.cancel', params);
  }

  async retryRun(params: BurnBarRunRetryRequest): Promise<BurnBarRunDetailResponse> {
    return this.send('run.retry', params);
  }

  async executeTool(params: BurnBarToolExecutionRequest): Promise<BurnBarToolExecutionResponse> {
    return this.send('workspace.executeTool', params);
  }

  async submitToolResult(params: BurnBarToolResultSubmissionRequest): Promise<BurnBarRunDetailResponse> {
    return this.send('workspace.toolResult', params);
  }

  async respondToApproval(params: OpenBurnBarApprovalRespondRequest): Promise<BurnBarRunDetailResponse> {
    return this.send('approval.respond', params);
  }

  async searchQuery(params: BurnBarSearchQueryParams): Promise<BurnBarSearchQueryDaemonResult> {
    return this.send<BurnBarSearchQueryDaemonResult, BurnBarSearchQueryParams>('daemon.search.query', params);
  }

  // Mission methods
  async missionApprove(params: BurnBarMissionApproveRequest): Promise<BurnBarMissionMutationResponse> {
    return this.send('daemon.mission.approve', params);
  }

  async missionList(params: BurnBarMissionListRequest): Promise<BurnBarMissionListResponse> {
    return this.send('daemon.mission.list', params);
  }

  async missionGet(params: BurnBarMissionGetRequest): Promise<BurnBarMissionMutationResponse> {
    return this.send('daemon.mission.get', params);
  }

  // Question methods
  async questionAnswer(params: BurnBarQuestionAnswerRequest): Promise<BurnBarQuestionAnswerResponse> {
    return this.send('daemon.question.answer', params);
  }

  async questionsList(params: BurnBarQuestionsListRequest): Promise<BurnBarQuestionsListResponse> {
    return this.send('daemon.question.list', params);
  }

  // Controller methods
  async controllerSummary(): Promise<BurnBarControllerSummaryResponse> {
    return this.send('daemon.controller.summary', {});
  }

  private async send<Result, Params = undefined>(method: BurnBarRPCMethod, params?: Params): Promise<Result> {
    if (this.inFlight >= this.maxInFlight) {
      throw new OpenBurnBarDaemonClientError(
        `OpenBurnBar daemon client has ${this.inFlight} RPCs in flight; refusing to queue ${method}.`
      );
    }

    this.inFlight += 1;
    const payload = JSON.stringify(this.makeEnvelope(method, params)) + '\n';

    try {
      return await new Promise<Result>((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      let responseBuffer = '';
      let settled = false;

      const timeout = setTimeout(() => {
        socket.destroy();
        fail(new OpenBurnBarDaemonClientError(`Timed out waiting for OpenBurnBar daemon on ${this.socketPath}.`));
      }, this.timeoutMs);

      const cleanup = () => {
        clearTimeout(timeout);
        socket.removeAllListeners();
      };

      const fail = (error: Error) => {
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        reject(error);
      };

      socket.setEncoding('utf8');

      socket.on('connect', () => {
        socket.write(payload);
      });

      socket.on('data', (chunk: string) => {
        responseBuffer += chunk;
        const newlineIndex = responseBuffer.indexOf('\n');
        if (newlineIndex === -1) {
          return;
        }

        const line = responseBuffer.slice(0, newlineIndex).trim();
        if (!line) {
          fail(new OpenBurnBarDaemonClientError('OpenBurnBar daemon returned an empty response.'));
          return;
        }

        try {
          const envelope = JSON.parse(line) as BurnBarRPCResponseEnvelope<Result>;
          if (envelope.error) {
            fail(new OpenBurnBarDaemonClientError(envelope.error.message));
            return;
          }

          if (!envelope.result) {
            fail(new OpenBurnBarDaemonClientError('OpenBurnBar daemon returned no result payload.'));
            return;
          }

          if (envelope.protocolVersion !== BURNBAR_PROTOCOL_VERSION) {
            fail(
              new OpenBurnBarDaemonClientError(
                `OpenBurnBar protocol mismatch. Expected ${BURNBAR_PROTOCOL_VERSION}, received ${envelope.protocolVersion}.`
              )
            );
            return;
          }

          settled = true;
          cleanup();
          resolve(envelope.result);
          socket.end();
        } catch (error) {
          fail(
            error instanceof Error
              ? error
              : new OpenBurnBarDaemonClientError('Failed to parse OpenBurnBar daemon response.')
          );
        }
      });

      socket.on('error', (error) => {
        fail(
          new OpenBurnBarDaemonClientError(
            `Unable to reach the local OpenBurnBar daemon on ${this.socketPath}: ${error.message}`
          )
        );
      });

      socket.on('end', () => {
        if (!settled && responseBuffer.trim().length === 0) {
          fail(new OpenBurnBarDaemonClientError('OpenBurnBar daemon closed the connection before replying.'));
        }
      });
      });
    } finally {
      this.inFlight -= 1;
    }
  }

  private makeEnvelope(method: BurnBarRPCMethod, params?: unknown): BurnBarRPCRequestEnvelope | BurnBarRPCRequestEnvelopeWithParams<unknown> {
    const base = {
      id: randomUUID(),
      method,
      ...(this.authToken ? { authToken: this.authToken } : {})
    };

    if (typeof params === 'undefined') {
      return base;
    }

    return {
      ...base,
      params
    };
  }
}
