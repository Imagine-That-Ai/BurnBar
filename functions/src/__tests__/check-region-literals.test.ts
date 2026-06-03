import { describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";

const REPO_ROOT = resolve(__dirname, "../../..");
const SRC_DIR = resolve(REPO_ROOT, "functions/src");
const GUARD = "scripts/ci/check-region-literals.mjs";

function runGuard(): { code: number; stdout: string; stderr: string } {
  try {
    const stdout = execFileSync("node", [GUARD], { cwd: REPO_ROOT, encoding: "utf8" });
    return { code: 0, stdout, stderr: "" };
  } catch (err) {
    const e = err as { status?: number; stdout?: string; stderr?: string };
    return { code: e.status ?? 1, stdout: e.stdout ?? "", stderr: e.stderr ?? "" };
  }
}

describe("check-region-literals.mjs", () => {
  it("passes on the current tree", () => {
    const { code, stdout } = runGuard();
    expect(code).toBe(0);
    expect(stdout).toContain("No raw region literals");
  });

  it("fails when a raw region literal is injected", () => {
    // Write a throwaway file with a raw literal into functions/src, run the
    // guard, and confirm it fails. The temp dir is removed regardless.
    const dir = mkdtempSync(resolve(SRC_DIR, "__region_guard_fixture_"));
    const file = resolve(dir, "injected.ts");
    try {
      writeFileSync(file, 'export const region = "us-central1";\n', "utf8");
      const { code, stderr } = runGuard();
      expect(code).toBe(1);
      expect(stderr).toContain("us-central1");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
