import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const REPO_ROOT = resolve(__dirname, "../../..");

describe("verify-resilience-wiring.sh", () => {
  it("passes on the current tree", () => {
    const out = execFileSync("bash", ["scripts/ci/verify-resilience-wiring.sh"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
    });
    expect(out).toContain("PASS");
  });
});
