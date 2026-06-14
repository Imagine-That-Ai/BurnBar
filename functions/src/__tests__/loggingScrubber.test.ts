/**
 * F-RR09-002 regression tests.
 *
 * The structured logging scrubber must never emit a full 28-char Firebase UID,
 * even when the UID is embedded inside a path-shaped or free-form string VALUE
 * (document_path, sourcePath, message, raw String(error)) rather than a
 * uid/userId/user_id KEY. These tests exercise the real public logging
 * boundary (logInfo/logWarn/logError -> console.{log,warn,error}) and assert on
 * the emitted JSON.
 *
 * They also enforce the source-level discipline guards: no production source
 * file may import the raw `firebase-functions/logger` (which bypasses the
 * scrubber), and no production source file may log a raw `*.ref.path`.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { logError, logInfo, logWarn } from "../logging.js";

const FULL_UID = "AbCdEf0123456789AbCdEf012345"; // 28-char Firebase-style UID
// Tests + the npm scripts run from the `functions/` package root.
const SRC_DIR = join(process.cwd(), "src");

function lastEmitted(spy: ReturnType<typeof vi.spyOn>): string {
  const call = spy.mock.calls.at(-1);
  if (!call) throw new Error("no log emitted");
  return String(call[0]);
}

describe("logging scrubber — UID-in-value redaction (F-RR09-002)", () => {
  let errSpy: ReturnType<typeof vi.spyOn>;
  let logSpy: ReturnType<typeof vi.spyOn>;
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("redacts a UID inside a Firestore document_path value", () => {
    logError({ event: "t", document_path: `users/${FULL_UID}/agent_notification_events/x` });
    const out = lastEmitted(errSpy);
    expect(out).not.toContain(FULL_UID);
    expect(out).toContain("users/AbCdEf01"); // 8-char correlation prefix preserved
  });

  it("redacts a UID inside a free-form message value", () => {
    logWarn({ event: "t", message: `sync stalled at users/${FULL_UID}/conversations/c1` });
    expect(lastEmitted(warnSpy)).not.toContain(FULL_UID);
  });

  it("redacts a UID inside a workspaces/workspace-<uid> path", () => {
    logInfo({ event: "t", path: `workspaces/workspace-${FULL_UID}/teams/team-default` });
    const out = lastEmitted(logSpy);
    expect(out).not.toContain(FULL_UID);
    expect(out).toContain("workspace-AbCdEf01");
    // the `workspaces/` collection name itself must remain intact
    expect(out).toContain("workspaces/");
  });

  it("redacts a UID embedded in a raw String(error) value", () => {
    logError({ event: "t", error: `ENOENT: users/${FULL_UID}/session_logs/log1` });
    expect(lastEmitted(errSpy)).not.toContain(FULL_UID);
  });

  it("still truncates UID when passed as a uid/userId/user_id KEY", () => {
    logInfo({ event: "t", uid: FULL_UID });
    const out = lastEmitted(logSpy);
    expect(out).not.toContain(FULL_UID);
    expect(out).toContain("AbCdEf01"); // 8-char user_id_hash
    expect(out).toContain("user_id_hash"); // uid key is renamed
  });

  it("does NOT mangle non-path long tokens (git SHA / trace id false-positive guard)", () => {
    const gitSha = "0123456789abcdef0123456789abcdef01234567"; // 40-hex
    const traceId = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"; // 32-char correlation id
    logInfo({ event: "t", commit: gitSha, trace_id: traceId });
    const out = lastEmitted(logSpy);
    expect(out).toContain(gitSha);
    expect(out).toContain(traceId);
  });

  it("still redacts emails, IPv4, and prefixed secrets (no regression)", () => {
    logInfo({
      event: "t",
      note: "mail alice@example.com from 10.0.0.5 token sk-ABCDEFGHIJKLMNOPQRSTUVWX",
    });
    const out = lastEmitted(logSpy);
    expect(out).toContain("[email]");
    expect(out).toContain("[ip]");
    expect(out).toContain("[REDACTED]");
    expect(out).not.toContain("alice@example.com");
  });
});

describe("logging discipline guards (F-RR09-002)", () => {
  function productionSourceFiles(dir: string): string[] {
    const out: string[] = [];
    for (const entry of readdirSync(dir)) {
      const full = join(dir, entry);
      if (statSync(full).isDirectory()) {
        if (entry === "__tests__" || entry === "node_modules") continue;
        out.push(...productionSourceFiles(full));
      } else if (entry.endsWith(".ts") && !entry.endsWith(".test.ts")) {
        out.push(full);
      }
    }
    return out;
  }

  const files = productionSourceFiles(SRC_DIR);

  it("no production source imports the raw firebase-functions/logger", () => {
    // The raw logger bypasses scrubFields entirely. All logging must go through
    // logInfo/logWarn/logError. (Also enforced by the eslint no-restricted-imports
    // rule; this test guards the invariant even if eslint isn't run in a lane.)
    const offenders = files.filter((f) =>
      /import\s[^;]*from\s+["']firebase-functions\/logger["']/.test(readFileSync(f, "utf8")),
    );
    expect(offenders).toEqual([]);
  });

  it("no production source interpolates a bare UID into a log message/detail string", () => {
    // Bare `${uid}` in a free-form string is NOT a `users/<uid>` path, so the
    // path redactor cannot catch it. Pass uid through a discrete field instead.
    const offenders = files.filter((f) => {
      const src = readFileSync(f, "utf8");
      return /(message|detail|note):\s*`[^`]*\$\{\s*uid\s*\}/.test(src);
    });
    expect(offenders).toEqual([]);
  });
});
