#!/usr/bin/env node
/**
 * CI ratchet — local-service endpoint literals must come from the registry.
 *
 * `LocalServiceRegistry.swift` (OpenBurnBarPlatformSupport) is the single
 * source of truth for the loopback services the app and daemon talk to
 * (BurnBar gateway, Hermes, Pi Agents, OpenClaw, Ollama, MLX, SmartHub).
 * Hardcoded `127.0.0.1:<port>` / `localhost:<port>` literals drifted across
 * ~90 sites once — this check fails when a non-test Swift file references a
 * registered default port in `host:port` form on a non-comment line.
 *
 * Allowed exceptions:
 *   - LocalServiceRegistry.swift itself (defines the numbers).
 *   - Lines that are `//` or `///` comments.
 *   - The VibeProxy legacy port is only allowed via
 *     `LegacyLocalEndpoint.vibeProxyPort` — a literal `host:8317` is still
 *     flagged even though VibeProxy owns the same port, so migration code
 *     cannot silently couple to the gateway default.
 *
 * Usage:  node scripts/ci/check-local-service-literals.mjs
 * Exit:   0 = clean, 1 = drift found, 2 = error.
 */

import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const REGISTRY_PATH = path.join(
  REPO_ROOT,
  "OpenBurnBarCore/Sources/OpenBurnBarPlatformSupport/LocalServiceRegistry.swift",
);
const SCAN_DIRS = [
  path.join(REPO_ROOT, "AgentLens"),
  path.join(REPO_ROOT, "OpenBurnBarDaemon"),
  path.join(REPO_ROOT, "OpenBurnBarCore", "Sources"),
];

/** Parse `defaultPort: N` entries out of the registry source. */
async function registeredPorts() {
  const source = await fs.readFile(REGISTRY_PATH, "utf8");
  const ports = [...source.matchAll(/defaultPort:\s*(\d+)/g)].map((m) => Number(m[1]));
  const legacy = [...source.matchAll(/public static let vibeProxyPort\s*=\s*(\d+)/g)].map(
    (m) => Number(m[1]),
  );
  return { ports, legacy };
}

async function* swiftFiles(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name === ".build") continue;
      yield* swiftFiles(full);
    } else if (entry.name.endsWith(".swift") && !entry.name.includes("Test")) {
      yield full;
    }
  }
}

export async function findLiteralViolations(root = REPO_ROOT) {
  const { ports, legacy } = await registeredPorts();
  const banned = new Set([...ports, ...legacy]);
  const offenders = [];
  for (const dir of SCAN_DIRS) {
    for await (const file of swiftFiles(dir)) {
      if (file === REGISTRY_PATH) continue;
      const lines = (await fs.readFile(file, "utf8")).split("\n");
      for (const [index, raw] of lines.entries()) {
        const line = raw.trim();
        if (line.startsWith("//") || line.startsWith("*")) continue;
        for (const port of banned) {
          const re = new RegExp(`(?:127\\.0\\.0\\.1|localhost)\\s*:\\s*${port}\\b`);
          if (re.test(line)) {
            offenders.push(`${path.relative(root, file)}:${index + 1} — ${line.slice(0, 120)}`);
            break;
          }
        }
      }
    }
  }
  return offenders;
}

async function main() {
  const offenders = await findLiteralViolations();
  if (offenders.length === 0) {
    console.log("check-local-service-literals: clean — no hardcoded registered local-service endpoints.");
    return;
  }
  console.error(`check-local-service-literals: ${offenders.length} hardcoded local-service endpoint literal(s) found:`);
  for (const line of offenders) console.error(`  ${line}`);
  console.error("Use LocalService.<service>.defaultBaseURL / defaultPort / matchesLoopbackEndpoint from LocalServiceRegistry.swift instead.");
  process.exitCode = 1;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(`check-local-service-literals: ${error.message}`);
    process.exitCode = 2;
  });
}
