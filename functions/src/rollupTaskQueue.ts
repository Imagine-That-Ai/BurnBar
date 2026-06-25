/**
 * @fileoverview Cloud Tasks fan-out for per-user usage rollup rebuilds.
 *
 * The scheduler owns discovery of dirty users; Cloud Tasks owns bounded
 * per-user execution. Task names include the dirty epoch so scheduler retries
 * are idempotent while newer usage writes naturally get a new task.
 */

import { createHash } from "node:crypto";
import type { protos } from "@google-cloud/tasks";
import { getConfig } from "./config.js";
import { isRecord } from "./guards.js";
import { logInfo, logWarn } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";

const ROLLUP_USER_REBUILD_TASK_FUNCTION = "rollupUserRebuild";
export const ROLLUP_USER_REBUILD_TASK_QUEUE_ID = "rollup-user-rebuilds";

type RollupUserRebuildTaskData = {
  uid: string;
  dirtiedAt?: string;
  requeueNonce?: string;
};

type RollupUserRebuildQueueJob = RollupUserRebuildTaskData;

type RollupTaskQueueConfig = {
  projectId: string;
  location: string;
  queueId: string;
  functionName: string;
  serviceAccountEmail: string;
  targetUri?: string;
};

type CloudTasksClientLike = {
  queuePath(project: string, location: string, queue: string): string;
  taskPath(project: string, location: string, queue: string, task: string): string;
  createTask(request: { parent: string; task: protos.google.cloud.tasks.v2.ITask }): Promise<unknown>;
};

type RollupTaskBuildResult = {
  parent: string;
  task: protos.google.cloud.tasks.v2.ITask;
  taskId: string;
};

type RollupTaskEnqueueResult = {
  attempted: number;
  enqueued: number;
  duplicates: number;
  queuePath: string;
};

let cachedCloudTasksClient: CloudTasksClientLike | undefined;
const functionUriCache = new Map<string, string>();

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}

function errorField(error: unknown, field: "code" | "message"): unknown {
  return isRecord(error) ? error[field] : undefined;
}

export function parseRollupUserRebuildTaskData(data: unknown): RollupUserRebuildTaskData | undefined {
  if (!isRecord(data)) return undefined;
  const uid = nonEmptyString(data.uid);
  if (!uid) return undefined;
  const dirtiedAt = nonEmptyString(data.dirtiedAt);
  const requeueNonce = nonEmptyString(data.requeueNonce);
  return {
    uid,
    ...(dirtiedAt ? { dirtiedAt } : {}),
    ...(requeueNonce ? { requeueNonce } : {}),
  };
}

function getRollupTaskQueueConfig(): RollupTaskQueueConfig {
  const { projectId } = getConfig();
  const location = process.env.ROLLUP_REBUILD_TASK_LOCATION ?? FUNCTIONS_REGION;
  const queueId = process.env.ROLLUP_REBUILD_TASK_QUEUE_ID ?? ROLLUP_USER_REBUILD_TASK_QUEUE_ID;
  const functionName = process.env.ROLLUP_REBUILD_TASK_FUNCTION_NAME ?? ROLLUP_USER_REBUILD_TASK_FUNCTION;
  return {
    projectId,
    location,
    queueId,
    functionName,
    targetUri: process.env.ROLLUP_REBUILD_TASK_TARGET_URI,
    serviceAccountEmail:
      process.env.ROLLUP_REBUILD_TASK_SERVICE_ACCOUNT_EMAIL ?? `${projectId}@appspot.gserviceaccount.com`,
  };
}

function taskEpoch(job: RollupUserRebuildQueueJob): string {
  return `${job.dirtiedAt ?? "missing-dirtied-at"}\0${job.requeueNonce ?? "initial"}`;
}

export function rollupUserRebuildTaskId(job: RollupUserRebuildQueueJob): string {
  const hash = createHash("sha256")
    .update(`${job.uid}\0${taskEpoch(job)}`)
    .digest("hex")
    .slice(0, 32);
  return `usage-rollup-${hash}`;
}

export function buildRollupUserRebuildTask(args: {
  client: CloudTasksClientLike;
  config: RollupTaskQueueConfig;
  targetUri: string;
  job: RollupUserRebuildQueueJob;
}): RollupTaskBuildResult {
  const { client, config, targetUri, job } = args;
  const parent = client.queuePath(config.projectId, config.location, config.queueId);
  const taskId = rollupUserRebuildTaskId(job);
  const body = Buffer.from(JSON.stringify({ data: job }));
  const task: protos.google.cloud.tasks.v2.ITask = {
    name: client.taskPath(config.projectId, config.location, config.queueId, taskId),
    dispatchDeadline: { seconds: 540 },
    httpRequest: {
      url: targetUri,
      httpMethod: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      oidcToken: {
        serviceAccountEmail: config.serviceAccountEmail,
        audience: targetUri,
      },
    },
  };
  return { parent, task, taskId };
}

export function isAlreadyExistsError(error: unknown): boolean {
  const code = errorField(error, "code");
  if (code === 6 || code === "6" || code === "ALREADY_EXISTS") return true;
  const message = String(errorField(error, "message") ?? (error instanceof Error ? error.message : error));
  return /\bALREADY_EXISTS\b|\balready exists\b/i.test(message);
}

async function getCloudTasksClient(): Promise<CloudTasksClientLike> {
  if (!cachedCloudTasksClient) {
    const { CloudTasksClient } = await import("@google-cloud/tasks");
    const client = new CloudTasksClient();
    cachedCloudTasksClient = {
      queuePath: (project, location, queue) => client.queuePath(project, location, queue),
      taskPath: (project, location, queue, task) => client.taskPath(project, location, queue, task),
      createTask: (request) => client.createTask(request),
    };
  }
  return cachedCloudTasksClient;
}

async function resolveCloudFunctionUri(config: RollupTaskQueueConfig): Promise<string> {
  if (config.targetUri) return config.targetUri;

  const cacheKey = `${config.projectId}/${config.location}/${config.functionName}`;
  const cached = functionUriCache.get(cacheKey);
  if (cached) return cached;

  const { google } = await import("googleapis");
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/cloud-platform"],
  });
  const cloudfunctions = google.cloudfunctions("v2");
  const name = `projects/${config.projectId}/locations/${config.location}/functions/${config.functionName}`;
  const response = await cloudfunctions.projects.locations.functions.get({
    auth,
    name,
  });
  const uri = response.data.serviceConfig?.uri;
  if (!uri) {
    throw new Error(`Unable to resolve Cloud Functions v2 URI for ${name}`);
  }
  functionUriCache.set(cacheKey, uri);
  return uri;
}

export async function enqueueRollupUserRebuildTasks(
  jobs: RollupUserRebuildQueueJob[],
  options: {
    client?: CloudTasksClientLike;
    config?: RollupTaskQueueConfig;
    targetUri?: string;
  } = {},
): Promise<RollupTaskEnqueueResult> {
  const config = options.config ?? getRollupTaskQueueConfig();
  const client = options.client ?? (await getCloudTasksClient());
  const targetUri = options.targetUri ?? (await resolveCloudFunctionUri(config));
  let enqueued = 0;
  let duplicates = 0;
  let queuePath = client.queuePath(config.projectId, config.location, config.queueId);

  for (const job of jobs) {
    const request = buildRollupUserRebuildTask({ client, config, targetUri, job });
    queuePath = request.parent;
    try {
      await client.createTask({ parent: request.parent, task: request.task });
      enqueued += 1;
      logInfo({ event: "rollup.task_enqueued", uid: job.uid, dirtiedAt: job.dirtiedAt, taskId: request.taskId });
    } catch (error) {
      if (isAlreadyExistsError(error)) {
        duplicates += 1;
        logInfo({
          event: "rollup.task_enqueue_duplicate",
          uid: job.uid,
          dirtiedAt: job.dirtiedAt,
          taskId: request.taskId,
        });
        continue;
      }
      logWarn({
        event: "rollup.task_enqueue_failed",
        uid: job.uid,
        dirtiedAt: job.dirtiedAt,
        taskId: request.taskId,
        error: String(errorField(error, "message") ?? (error instanceof Error ? error.message : error)),
      });
      throw error;
    }
  }

  return { attempted: jobs.length, enqueued, duplicates, queuePath };
}
