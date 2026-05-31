/**
 * Observability wrappers for scheduled workers and Firestore triggers.
 */

import { captureException } from "./sentry.js";
import { logError, logInfo } from "./logging.js";
import { firestoreWithResilience } from "./resilienceHelpers.js";

export async function runScheduledJob<T>(name: string, fn: () => Promise<T>): Promise<T | undefined> {
  logInfo({ event: "scheduled_job_start", job: name });
  try {
    const result = await fn();
    logInfo({ event: "scheduled_job_success", job: name });
    return result;
  } catch (error) {
    captureException(error, { scheduled_job: name });
    logError({ event: "scheduled_job_failed", job: name, error: String(error) });
    throw error;
  }
}

/** Firestore read/write batches inside scheduled jobs. */
export async function scheduledFirestore<T>(label: string, fn: () => Promise<T>): Promise<T> {
  return firestoreWithResilience(`scheduled:${label}`, fn);
}

/** Firestore background triggers (usage, notifications, etc.). */
export async function runFirestoreTrigger<T>(name: string, fn: () => Promise<T>): Promise<T | undefined> {
  return runScheduledJob(`trigger:${name}`, fn);
}
