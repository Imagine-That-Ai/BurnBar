import { readFileSync, readdirSync, existsSync } from "node:fs";
import { relative } from "node:path";
import { fileURLToPath } from "node:url";

import { describe, expect, it } from "vitest";

const packageEngineDir = fileURLToPath(
  new URL("../../../../packages/gl-engine/src/engine/", import.meta.url),
);
const consoleEngineDir = fileURLToPath(
  new URL("../../lib/gl/engine/", import.meta.url),
);

/** Recursively collect every file path under `dir`, relative to `dir`. */
function collectRelativeFiles(dir: string, base = dir): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = `${dir}/${entry.name}`;
    if (entry.isDirectory()) {
      out.push(...collectRelativeFiles(full, base));
    } else if (entry.isFile()) {
      out.push(relative(base, full));
    }
  }
  return out;
}

describe("GL engine parity gate", () => {
  it("every package engine file is byte-identical in the console engine dir", () => {
    const packageFiles = collectRelativeFiles(packageEngineDir);
    expect(packageFiles.length).toBeGreaterThan(0);

    const mismatches: string[] = [];
    for (const rel of packageFiles) {
      const packagePath = `${packageEngineDir}/${rel}`;
      const consolePath = `${consoleEngineDir}/${rel}`;
      if (!existsSync(consolePath)) {
        mismatches.push(`MISSING in console: ${rel}`);
        continue;
      }
      const pkgBytes = readFileSync(packagePath);
      const consoleBytes = readFileSync(consolePath);
      if (pkgBytes.length !== consoleBytes.length || !pkgBytes.equals(consoleBytes)) {
        mismatches.push(`DIFFERS: ${rel}`);
      }
    }

    expect(mismatches, `Engine files diverge:\n${mismatches.join("\n")}`).toEqual([]);
  });

  it("no extra files exist in the console engine dir that are absent from the package dir", () => {
    const packageFiles = new Set(collectRelativeFiles(packageEngineDir));
    const consoleFiles = collectRelativeFiles(consoleEngineDir);

    const extras = consoleFiles.filter((f) => !packageFiles.has(f));
    expect(extras, `Extra files in console engine dir:\n${extras.join("\n")}`).toEqual([]);
  });
});

describe("GL engine union features", () => {
  const backdropSource = readFileSync(
    `${consoleEngineDir}/BackdropEngine.ts`,
    "utf8",
  );
  const registrySource = readFileSync(`${consoleEngineDir}/registry.ts`, "utf8");
  const typesSource = readFileSync(`${consoleEngineDir}/types.ts`, "utf8");

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

  it("kernels/swarmEmberKernel.ts exists in both engine dirs", () => {
    expect(existsSync(`${packageEngineDir}/kernels/swarmEmberKernel.ts`)).toBe(true);
    expect(existsSync(`${consoleEngineDir}/kernels/swarmEmberKernel.ts`)).toBe(true);
  });
});