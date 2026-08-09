/**
 * Stable automation readiness identifiers shared by the Linux shell and its
 * capture/verification harnesses.
 *
 * The shell publishes `.shell[data-shell-ready='ready']` once the backdrop
 * has mounted and emitted at least one readability profile (App.tsx), and
 * exposes `data-testid` hooks on the kernel switcher. Harnesses must wait on
 * SHELL_READY_SELECTOR before interacting instead of polling child controls
 * like `.kernel-switcher-trigger`, which time out when boot is slow.
 */

export const SHELL_READY_SELECTOR = ".shell[data-shell-ready='ready']";
export const KERNEL_SWITCHER_TRIGGER_SELECTOR = "[data-testid='kernel-switcher-trigger']";
export const KERNEL_SWITCHER_PANEL_SELECTOR = "[data-testid='kernel-switcher-panel']";
export const BACKDROP_CANVAS_SELECTOR = ".kernel-backdrop[data-backdrop-mode='canvas']";
export const BACKDROP_CSS_SELECTOR = ".kernel-backdrop[data-backdrop-mode='css']";

export const DEFAULT_READINESS_TIMEOUT_MS = 45_000;

/**
 * Run an interaction with bounded retries for transient failures. Retries
 * only errors that look transient (timeouts, detached/renavigated targets);
 * assertion-style product failures propagate immediately so real defects are
 * never retried into silence. Returns { value, attempts, recovered }.
 */
export async function withReadinessRetry(action, {
  attempts = 3,
  isTransient = isTransientAutomationError,
  onRetry = null,
  delayMs = 500,
  sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms))
} = {}) {
  if (!Number.isSafeInteger(attempts) || attempts < 1) {
    throw new Error('withReadinessRetry attempts must be a positive integer');
  }
  let lastError = null;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const value = await action(attempt);
      return { value, attempts: attempt, recovered: attempt > 1 };
    } catch (error) {
      lastError = error;
      if (attempt === attempts || !isTransient(error)) throw error;
      await onRetry?.(error, attempt);
      await sleep(delayMs);
    }
  }
  throw lastError;
}

export function isTransientAutomationError(error) {
  const message = error instanceof Error ? error.message : String(error ?? '');
  return /Timeout \d+ms exceeded|waiting for|Target closed|Execution context was destroyed|Element is not attached|frame was detached/iu
    .test(message);
}
