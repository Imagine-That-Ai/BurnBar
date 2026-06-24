#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const GENERATOR = join(SCRIPT_DIR, "generate-macos-appcast.mjs");
const roots = [];

process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "openburnbar-appcast-"));
  roots.push(root);
  writeFileSync(join(root, "OpenBurnBar-1.2.3-macOS.dmg"), "dmg\n");
  writeFileSync(join(root, "OpenBurnBar-1.2.3-macOS.zip"), "zip\n");
  writeFileSync(join(root, "OpenBurnBar-1.2.3-corresponding-source.tar.gz"), "source\n");
  return root;
}

function args(root, overrides = {}) {
  const values = {
    "version": "1.2.3",
    "build": "123",
    "bundle-id": "com.openburnbar.app",
    "release-dir": root,
    "dmg-name": "OpenBurnBar-1.2.3-macOS.dmg",
    "zip-name": "OpenBurnBar-1.2.3-macOS.zip",
    "source-archive-name": "OpenBurnBar-1.2.3-corresponding-source.tar.gz",
    "base-url": "https://github.com/Imagine-That-Ai/BurnBar/releases/download/v1.2.3",
    "commit": "0123456789abcdef0123456789abcdef01234567",
    "appcast-name": "appcast.xml",
    "latest-name": "latest-macos.json",
    "ed-signature": "signature",
    ...overrides,
  };
  return Object.entries(values).flatMap(([key, value]) => [`--${key}`, value]);
}

function run(root, overrides = {}) {
  try {
    const stdout = execFileSync("node", [GENERATOR, ...args(root, overrides)], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { status: 0, output: stdout };
  } catch (error) {
    return {
      status: error.status ?? 1,
      output: `${error.stdout?.toString() ?? ""}${error.stderr?.toString() ?? ""}`,
    };
  }
}

let passed = 0;
let failed = 0;

function expect(label, fn) {
  try {
    fn();
    console.log(`  PASS ${label}`);
    passed += 1;
  } catch (error) {
    console.error(`  FAIL ${label}: ${error.message}`);
    failed += 1;
  }
}

console.log("Self-test: generate-macos-appcast.mjs\n");

expect("valid release artifacts generate appcast and latest metadata", () => {
  const root = fixture();
  const result = run(root);
  if (result.status !== 0) throw new Error(result.output);
  const latest = JSON.parse(readFileSync(join(root, "latest-macos.json"), "utf8"));
  if (latest.dmg !== "OpenBurnBar-1.2.3-macOS.dmg") {
    throw new Error("latest metadata did not reference the expected DMG");
  }
  if (!existsSync(join(root, "appcast.xml"))) {
    throw new Error("appcast.xml was not written");
  }
});

expect("output name traversal is rejected before writing outside release dir", () => {
  const root = fixture();
  const outside = join(dirname(root), "owned-appcast.xml");
  const result = run(root, { "appcast-name": "../owned-appcast.xml" });
  if (result.status === 0) throw new Error("traversal unexpectedly passed");
  if (existsSync(outside)) throw new Error("traversal wrote outside release dir");
});

expect("artifact name traversal is rejected", () => {
  const root = fixture();
  const result = run(root, { "dmg-name": "../OpenBurnBar-1.2.3-macOS.dmg" });
  if (result.status === 0) throw new Error("artifact traversal unexpectedly passed");
});

expect("symlinked artifact is rejected", () => {
  const root = fixture();
  symlinkSync(join(root, "OpenBurnBar-1.2.3-macOS.dmg"), join(root, "linked.dmg"));
  const result = run(root, { "dmg-name": "linked.dmg" });
  if (result.status === 0) throw new Error("symlinked DMG unexpectedly passed");
});

if (failed > 0) {
  console.error(`\n${failed} appcast generator self-test(s) failed.`);
  process.exit(1);
}

console.log(`\n${passed} appcast generator self-test(s) passed.`);
