import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const packageEngineDir = fileURLToPath(
  new URL("../../../../packages/gl-engine/src/engine/", import.meta.url),
);
const consoleEngineDir = fileURLToPath(
  new URL("../../lib/gl/engine/", import.meta.url),
);

describe("GL engine package is the only copy", () => {
  it("console must not keep a lib/gl/engine tree", () => {
    expect(
      existsSync(consoleEngineDir),
      "apps/console/lib/gl/engine must not exist; import @openburnbar/gl-engine",
    ).toBe(false);
  });

  it("package engine sources exist", () => {
    expect(existsSync(`${packageEngineDir}/BackdropEngine.ts`)).toBe(true);
    expect(existsSync(`${packageEngineDir}/registry.ts`)).toBe(true);
    expect(existsSync(`${packageEngineDir}/types.ts`)).toBe(true);
  });
});

describe("GL engine union features", () => {
  const backdropSource = readFileSync(`${packageEngineDir}/BackdropEngine.ts`, "utf8");
  const registrySource = readFileSync(`${packageEngineDir}/registry.ts`, "utf8");
  const typesSource = readFileSync(`${packageEngineDir}/types.ts`, "utf8");

  it("BackdropEngine declares low-power powerPreference", () => {
    expect(backdropSource).toContain('powerPreference: "low-power"');
  });

  it("BackdropEngine exposes setHostVisible method", () => {
    expect(backdropSource).toContain("setHostVisible");
  });

  it("BackdropEngine has private hostVisible = true field", () => {
    expect(backdropSource).toContain("private hostVisible = true");
  });

  it("BackdropEngine guards the rAF loop with !this.hostVisible", () => {
    expect(backdropSource).toContain("!this.hostVisible");
  });

  it("BackdropEngine applies a 300ms harvest throttle", () => {
    expect(backdropSource).toContain("now - this.lastHarvest < 300");
  });

  it("BackdropEngine exposes setPalette method", () => {
    expect(backdropSource).toContain("setPalette");
  });

  it("BackdropEngineOptions declares swarmEmberOptions", () => {
    expect(backdropSource).toContain("swarmEmberOptions");
  });

  it("BackdropEngineOptions declares palette?: KernelPalette", () => {
    expect(backdropSource).toContain("palette?: KernelPalette");
  });

  it("registry includes the swarmEmber kernel", () => {
    expect(registrySource).toContain('"swarmEmber"');
  });

  it("types includes swarmEmber in the KernelId union", () => {
    expect(typesSource).toContain('| "swarmEmber"');
  });

  it("kernels/swarmEmberKernel.ts exists in the package engine", () => {
    expect(existsSync(`${packageEngineDir}/kernels/swarmEmberKernel.ts`)).toBe(true);
  });
});
