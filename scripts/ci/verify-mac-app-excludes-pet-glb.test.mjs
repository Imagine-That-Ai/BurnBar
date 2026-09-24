#!/usr/bin/env node
/**
 * Diligence: 300+ MB of PetCompanion GLBs must stay in-tree for Living Themes
 * / wallpaper export, but must not copy into the default Mac app bundle.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const projectYml = readFileSync(join(repoRoot, "project.yml"), "utf8");
const pbxproj = readFileSync(
  join(repoRoot, "OpenBurnBar.xcodeproj/project.pbxproj"),
  "utf8",
);

test("project.yml keeps PetCompanion Models out of the default Mac sources and resources", () => {
  assert.match(
    projectYml,
    /Lab\/PetCompanion\/Resources\/Models\/\*\*/,
    "AgentLens sources must exclude the Models tree",
  );
  assert.match(
    projectYml,
    /NOT copied into the default Mac app bundle/,
    "project.yml must keep the diligence comment that Models stay out of the Mac app",
  );
  assert.doesNotMatch(
    projectYml,
    /path: AgentLens\/Lab\/PetCompanion\/Resources\/Models/,
    "project.yml must not add Models as a resources folder reference",
  );
});

test("OpenBurnBar Mac target resources do not copy the PetCompanion Models folder", () => {
  const targetMatch = pbxproj.match(
    /isa = PBXNativeTarget;\s*buildConfigurationList = [^;]+ \/\* Build configuration list for PBXNativeTarget "OpenBurnBar" \*\/;\s*buildPhases = \(([\s\S]*?)\);/,
  );
  assert.ok(targetMatch, "OpenBurnBar native target must exist");
  const resourcesPhaseId = [...targetMatch[1].matchAll(
    /([A-F0-9]{24}) \/\* Resources \*\//g,
  )].map((match) => match[1]);
  assert.equal(resourcesPhaseId.length, 1, "OpenBurnBar must have one Resources phase");

  const phasePattern = new RegExp(
    `${resourcesPhaseId[0]} /\\* Resources \\*/ = \\{[\\s\\S]*?files = \\(([\\s\\S]*?)\\);`,
  );
  const phaseMatch = pbxproj.match(phasePattern);
  assert.ok(phaseMatch, "OpenBurnBar Resources phase body must be parseable");
  assert.doesNotMatch(
    phaseMatch[1],
    /Models in Resources/,
    "default Mac app must not copy AgentLens/PetCompanion/Resources/Models",
  );
  assert.doesNotMatch(
    phaseMatch[1],
    /\.glb in Resources/,
    "default Mac app must not copy individual pet GLBs",
  );
});
