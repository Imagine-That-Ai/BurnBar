import type { protos } from "@google-cloud/tasks";
import { describe, expect, it, vi } from "vitest";
import {
  buildRollupUserRebuildTask,
  enqueueRollupUserRebuildTasks,
  isAlreadyExistsError,
  parseRollupUserRebuildTaskData,
  ROLLUP_USER_REBUILD_TASK_QUEUE_ID,
  rollupUserRebuildTaskId,
} from "../rollupTaskQueue.js";
import { shouldProcessRollupUserRebuildTask } from "../rollups.js";
import type { RollupJobDoc } from "../types.js";

vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});

const config = {
  projectId: "burnbar-test",
  location: "us-central1",
  queueId: ROLLUP_USER_REBUILD_TASK_QUEUE_ID,
  functionName: "rollupUserRebuild",
  serviceAccountEmail: "burnbar-test@appspot.gserviceaccount.com",
};

function fakeClient(createTask = vi.fn().mockResolvedValue({})) {
  return {
    queuePath: (project: string, location: string, queue: string) =>
      `projects/${project}/locations/${location}/queues/${queue}`,
    taskPath: (project: string, location: string, queue: string, task: string) =>
      `projects/${project}/locations/${location}/queues/${queue}/tasks/${task}`,
    createTask,
  };
}

function bodyJson(task: protos.google.cloud.tasks.v2.ITask): unknown {
  const body = task.httpRequest?.body;
  expect(body).toBeTruthy();
  if (body instanceof Uint8Array) {
    return JSON.parse(Buffer.from(body).toString("utf8"));
  }
  if (typeof body === "string") {
    return JSON.parse(Buffer.from(body, "base64").toString("utf8"));
  }
  throw new Error("unexpected Cloud Tasks body type");
}

function job(patch: Partial<RollupJobDoc>): RollupJobDoc {
  return { dirty: true, ...patch };
}

describe("rollup task queue fan-out", () => {
  it("builds Firebase task-queue-compatible Cloud Tasks requests", () => {
    const client = fakeClient();
    const result = buildRollupUserRebuildTask({
      client,
      config,
      targetUri: "https://rollup.example/rollupUserRebuild",
      job: { uid: "user-1", dirtiedAt: "2026-06-17T01:02:03.000Z" },
    });

    expect(result.parent).toBe("projects/burnbar-test/locations/us-central1/queues/rollup-user-rebuilds");
    expect(result.task.name).toContain(
      `/tasks/${rollupUserRebuildTaskId({ uid: "user-1", dirtiedAt: "2026-06-17T01:02:03.000Z" })}`,
    );
    expect(result.task.dispatchDeadline).toEqual({ seconds: 540 });
    expect(result.task.httpRequest?.httpMethod).toBe("POST");
    expect(result.task.httpRequest?.headers).toEqual({ "Content-Type": "application/json" });
    expect(result.task.httpRequest?.oidcToken).toEqual({
      serviceAccountEmail: "burnbar-test@appspot.gserviceaccount.com",
      audience: "https://rollup.example/rollupUserRebuild",
    });
    expect(bodyJson(result.task)).toEqual({
      data: { uid: "user-1", dirtiedAt: "2026-06-17T01:02:03.000Z" },
    });
  });

  it("uses dirty epoch in deterministic task ids", () => {
    const first = rollupUserRebuildTaskId({ uid: "same-user", dirtiedAt: "2026-06-17T01:02:03.000Z" });
    const second = rollupUserRebuildTaskId({ uid: "same-user", dirtiedAt: "2026-06-17T01:03:03.000Z" });
    expect(first).toBe(rollupUserRebuildTaskId({ uid: "same-user", dirtiedAt: "2026-06-17T01:02:03.000Z" }));
    expect(first).not.toBe(second);
  });

  it("treats duplicate task creation as idempotent enqueue success", async () => {
    const duplicate = Object.assign(new Error("ALREADY_EXISTS: task exists"), { code: 6 });
    const createTask = vi.fn().mockRejectedValueOnce(duplicate).mockResolvedValueOnce({});
    const client = fakeClient(createTask);

    const result = await enqueueRollupUserRebuildTasks(
      [
        { uid: "user-1", dirtiedAt: "2026-06-17T01:02:03.000Z" },
        { uid: "user-2", dirtiedAt: "2026-06-17T01:02:04.000Z" },
      ],
      {
        client,
        config,
        targetUri: "https://rollup.example/rollupUserRebuild",
      },
    );

    expect(isAlreadyExistsError(duplicate)).toBe(true);
    expect(createTask).toHaveBeenCalledTimes(2);
    expect(result).toMatchObject({ attempted: 2, enqueued: 1, duplicates: 1 });
  });

  it("validates task payloads before the worker touches Firestore", () => {
    expect(parseRollupUserRebuildTaskData({ uid: "user-1", dirtiedAt: "2026-06-17T01:02:03.000Z" })).toEqual({
      uid: "user-1",
      dirtiedAt: "2026-06-17T01:02:03.000Z",
    });
    expect(parseRollupUserRebuildTaskData({ uid: " user-1 " })).toEqual({ uid: "user-1" });
    expect(parseRollupUserRebuildTaskData({ uid: "" })).toBeUndefined();
    expect(parseRollupUserRebuildTaskData("bad")).toBeUndefined();
  });

  it("skips stale task epochs and fresh jobs before expensive rebuild work", () => {
    expect(
      shouldProcessRollupUserRebuildTask(
        job({ dirty: false, dirtiedAt: "2026-06-17T01:02:03.000Z" }),
        "2026-06-17T01:02:03.000Z",
      ),
    ).toEqual({
      process: false,
      reason: "not_dirty",
      currentDirtiedAt: "2026-06-17T01:02:03.000Z",
    });

    expect(
      shouldProcessRollupUserRebuildTask(job({ dirtiedAt: "2026-06-17T01:05:03.000Z" }), "2026-06-17T01:02:03.000Z"),
    ).toEqual({
      process: false,
      reason: "stale_dirty_epoch",
      currentDirtiedAt: "2026-06-17T01:05:03.000Z",
    });

    expect(
      shouldProcessRollupUserRebuildTask(job({ dirtiedAt: "2026-06-17T01:02:03.000Z" }), "2026-06-17T01:02:03.000Z"),
    ).toEqual({ process: true });
    expect(shouldProcessRollupUserRebuildTask(job({ dirtiedAt: "2026-06-17T01:02:03.000Z" }), undefined)).toEqual({
      process: true,
    });
  });
});
