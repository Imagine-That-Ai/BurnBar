#!/usr/bin/env node
/**
 * @fileoverview Stop two xcframeworks from claiming `include/module.modulemap`.
 *
 * `xcodebuild -create-xcframework -library X.a -headers H/` produces a slice
 * whose headers Xcode copies into a SHARED `BuildProductsPath/include` at build
 * time. A header directory containing `module.modulemap` therefore claims a
 * path no other binary target can also claim. Link two such xcframeworks into
 * one target and the build dies with:
 *
 *     error: Multiple commands produce '.../Release-iphoneos/include/module.modulemap'
 *
 * That is what blocked every OpenBurnBar iOS archive — and so every release —
 * in August 2026. It surfaces only when both are linked together, which is why
 * PR CI never saw it: the domain-core xcframework is built during the release
 * job and is not vendored.
 *
 * The invariant is not "never use the bare layout" — one bare-layout
 * xcframework is perfectly fine, and OpenBurnBarIroh has shipped that way for
 * a long time. The invariant is that **at most one** may. A second one is a
 * guaranteed collision, so the gate fails on the second.
 *
 * The fix for a new one is to package a real `.framework`, whose module map
 * lives inside the bundle at `Modules/module.modulemap` and cannot collide.
 * `scripts/build-burnbar-remote-xcframework.sh` and
 * `scripts/build-domain-core-xcframework.sh` both show the shape.
 *
 * Usage: node scripts/ci/verify-xcframework-modulemap-collision.mjs [--json]
 */

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.XCFRAMEWORK_COLLISION_ROOT ??
  resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * A script uses the collision-prone layout when it both writes a
 * `module.modulemap` into a headers directory and hands that directory to
 * `-create-xcframework` via `-headers`.
 */
export function usesBareHeaderLayout(source) {
  const writesRootModulemap = /\/Headers\/module\.modulemap"/u.test(source);
  const passesHeadersDir = /build_xcframework_args\+=\([^)]*-headers/u.test(source);
  return writesRootModulemap && passesHeadersDir;
}

export function auditXcframeworkScripts(root = ROOT) {
  const dir = join(root, "scripts");
  const scripts = readdirSync(dir)
    .filter((name) => /^build-.*xcframework\.sh$/u.test(name))
    .sort();
  return scripts.filter((name) =>
    usesBareHeaderLayout(readFileSync(join(dir, name), "utf8")),
  );
}

function main(argv) {
  const offenders = auditXcframeworkScripts();
  if (argv.includes("--json")) {
    process.stdout.write(`${JSON.stringify({ offenders }, null, 2)}\n`);
  }
  if (offenders.length > 1) {
    process.stderr.write(
      `::error::${offenders.length} xcframework build scripts emit a bare ` +
        "`Headers/module.modulemap`, so their slices collide on " +
        "`include/module.modulemap` in any target that links more than one: " +
        `${offenders.join(", ")}\n` +
        "Package the newer one as a real .framework — see " +
        "scripts/build-domain-core-xcframework.sh's make_framework() — so its " +
        "module map lives inside the bundle.\nBackground: docs/CI_RELEASE_RUNBOOK.md\n",
    );
    return 1;
  }
  process.stdout.write(
    `xcframework module map gate passed (${offenders.length} bare-layout script${
      offenders.length === 1 ? "" : "s"
    }; the limit is 1).\n`,
  );
  return 0;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
