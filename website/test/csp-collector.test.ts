import { describe, expect, it } from "vitest";
import {
  expectedMarketingCsps,
  extraCollectorConnectSrc,
} from "../scripts/update-csp-hashes.mjs";

const hashes = {
  scriptHashes: ["'sha256-script'"],
  styleElementHashes: ["'sha256-style'"],
  styleAttributeHashes: ["'sha256-attr'"],
};

const collectorOrigin = "https://collector.example";
const collectorEnv = {
  PUBLIC_ANALYTICS_COLLECTOR_URL: `${collectorOrigin}/v1/collect`,
};

describe("marketing CSP collector origin", () => {
  it("adds a distinct https collector origin", () => {
    expect(extraCollectorConnectSrc(collectorEnv)).toEqual([collectorOrigin]);
  });

  it("allows localhost collectors", () => {
    expect(
      extraCollectorConnectSrc({
        PUBLIC_ANALYTICS_COLLECTOR_URL: "http://localhost:8787/collect",
      }),
    ).toEqual(["http://localhost:8787"]);
  });

  it("rejects non-https remote collectors", () => {
    expect(
      extraCollectorConnectSrc({
        PUBLIC_ANALYTICS_COLLECTOR_URL: "http://evil.example/x",
      }),
    ).toEqual([]);
  });

  it("keeps --check / dark expected CSP collector-free when the env URL is set", () => {
    const dark = expectedMarketingCsps(hashes, {
      includeCollector: false,
      env: collectorEnv,
    });
    expect(dark.get("**")).toContain("connect-src 'self'");
    expect(dark.get("**")).not.toContain(collectorOrigin);
    expect(dark.get("/link")).not.toContain(collectorOrigin);
    expect(dark.get("/bench/arena/vote")).not.toContain(collectorOrigin);
  });

  it("includes the collector origin only when --write / deploy asks for it", () => {
    const live = expectedMarketingCsps(hashes, {
      includeCollector: true,
      env: collectorEnv,
    });
    expect(live.get("**")).toContain(`connect-src 'self' ${collectorOrigin}`);
    expect(live.get("/link")).toContain(collectorOrigin);
    expect(live.get("/bench/arena/vote")).toContain(collectorOrigin);
  });
});
