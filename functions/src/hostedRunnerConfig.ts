/**
 * @fileoverview Hosted quota runner secret wiring.
 *
 * The runner endpoint is non-secret configuration, but the bearer token
 * shared between Cloud Functions and Cloud Run must live in Secret Manager.
 */

import { defineSecret } from "firebase-functions/params";

import { getConfig } from "./config.js";

type SecretParam = ReturnType<typeof defineSecret>;

export const HOSTED_QUOTA_RUNNER_TOKEN: SecretParam = defineSecret(
  "HOSTED_QUOTA_RUNNER_TOKEN"
);

export const HOSTED_RUNNER_SECRETS: SecretParam[] = [
  HOSTED_QUOTA_RUNNER_TOKEN,
];

export function hostedQuotaRunnerToken(): string {
  return (
    HOSTED_QUOTA_RUNNER_TOKEN.value().trim() ||
    getConfig().hostedQuotaRunnerToken ||
    ""
  );
}
