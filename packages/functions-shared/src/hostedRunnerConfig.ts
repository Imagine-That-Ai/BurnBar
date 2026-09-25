/**
 * @fileoverview Hosted quota runner secret wiring.
 *
 * The runner endpoint is non-secret configuration, but the bearer token
 * shared between Cloud Functions and Cloud Run must live in Secret Manager.
 */

import { defineSecret } from "firebase-functions/params";

import { getConfig } from "./config.js";

type SecretParam = ReturnType<typeof defineSecret>;

const HOSTED_QUOTA_RUNNER_TOKEN: SecretParam = defineSecret("HOSTED_QUOTA_RUNNER_TOKEN");

export const HOSTED_RUNNER_SECRETS: SecretParam[] = [HOSTED_QUOTA_RUNNER_TOKEN];

export function hostedQuotaRunnerToken(): string {
  return HOSTED_QUOTA_RUNNER_TOKEN.value().trim() || getConfig().hostedQuotaRunnerToken || "";
}

function normalizedHostname(value: string): string {
  return value.trim().toLowerCase().replace(/\.$/u, "");
}

function allowedHostedQuotaRunnerHosts(): Set<string> {
  return new Set(getConfig().hostedQuotaRunnerAllowedHosts.map(normalizedHostname).filter(Boolean));
}

export function hostedQuotaRunnerRefreshEndpoint(rawURL = getConfig().hostedQuotaRunnerURL): URL {
  if (!rawURL) {
    throw new Error("failed-precondition: HOSTED_QUOTA_RUNNER_URL is not set.");
  }

  let baseURL: URL;
  try {
    baseURL = new URL(rawURL);
  } catch {
    throw new Error("failed-precondition: hosted quota runner URL is invalid.");
  }

  if (baseURL.protocol !== "https:") {
    throw new Error("failed-precondition: hosted quota runner must use HTTPS.");
  }
  if (baseURL.username || baseURL.password) {
    throw new Error("failed-precondition: hosted quota runner URL must not contain credentials.");
  }
  if (baseURL.port && baseURL.port !== "443") {
    throw new Error("failed-precondition: hosted quota runner must use the default HTTPS port.");
  }

  const endpoint = new URL("/v1/quota/refresh", baseURL);
  const allowedHosts = allowedHostedQuotaRunnerHosts();
  const endpointHost = normalizedHostname(endpoint.hostname);
  if (!allowedHosts.has(endpointHost)) {
    throw new Error("failed-precondition: hosted quota runner host is not allowlisted.");
  }
  return endpoint;
}
