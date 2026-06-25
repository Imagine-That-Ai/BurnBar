import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const TOUCHED = [
  "GCLOUD_PROJECT",
  "GOOGLE_CLOUD_PROJECT",
  "HOSTED_QUOTA_RUNNER_URL",
  "HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS",
] as const;

describe("hosted quota runner endpoint boundary", () => {
  const saved: Record<string, string | undefined> = {};

  beforeEach(() => {
    vi.resetModules();
    for (const key of TOUCHED) {
      saved[key] = process.env[key];
      delete process.env[key];
    }
    process.env.GCLOUD_PROJECT = "demo-project";
  });

  afterEach(() => {
    for (const key of TOUCHED) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  });

  it("resolves refresh posts only for explicitly allowlisted HTTPS runner hosts", async () => {
    process.env.HOSTED_QUOTA_RUNNER_URL = "https://OPENBURNBAR-QUOTA-RUNNER-ABC-UC.A.RUN.APP/custom/base?ignored=true";
    process.env.HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS = "openburnbar-quota-runner-abc-uc.a.run.app,other-runner.a.run.app";

    const { hostedQuotaRunnerRefreshEndpoint } = await import("../hostedRunnerConfig.js");

    expect(hostedQuotaRunnerRefreshEndpoint().href).toBe(
      "https://openburnbar-quota-runner-abc-uc.a.run.app/v1/quota/refresh",
    );
  });

  it("rejects arbitrary HTTPS hosts that are not in the runner allowlist", async () => {
    process.env.HOSTED_QUOTA_RUNNER_URL = "https://untrusted-runner.example/v1/quota/refresh";
    process.env.HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS = "openburnbar-quota-runner-abc-uc.a.run.app";

    const { hostedQuotaRunnerRefreshEndpoint } = await import("../hostedRunnerConfig.js");

    expect(() => hostedQuotaRunnerRefreshEndpoint()).toThrow(/host is not allowlisted/);
  });

  it("rejects runner URLs with embedded credentials or non-default HTTPS ports", async () => {
    process.env.HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS = "openburnbar-quota-runner-abc-uc.a.run.app";
    const { hostedQuotaRunnerRefreshEndpoint } = await import("../hostedRunnerConfig.js");

    expect(() =>
      hostedQuotaRunnerRefreshEndpoint("https://operator@openburnbar-quota-runner-abc-uc.a.run.app"),
    ).toThrow(/must not contain credentials/);
    expect(() => hostedQuotaRunnerRefreshEndpoint("https://openburnbar-quota-runner-abc-uc.a.run.app:8443")).toThrow(
      /default HTTPS port/,
    );
  });
});
