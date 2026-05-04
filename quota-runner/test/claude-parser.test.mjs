import test from "node:test";
import assert from "node:assert/strict";
import { fetchClaudeQuota, parseClaudeUsage } from "../src/providers/claude.mjs";

test("parseClaudeUsage extracts session and weekly quota buckets", () => {
  const buckets = parseClaudeUsage(`
Current session
███████ 15% used
Resets 4:09am (America/Chicago)

Current week (all models)
████████████████ 73% used
Resets May 6 at 1am (America/Chicago)

Current week (Sonnet only)
███ 7% used
Resets May 6 at 12:59am (America/Chicago)
`);
  assert.equal(buckets.length, 3);
  assert.equal(buckets[0].name, "Current session");
  assert.equal(buckets[0].used, 15);
  assert.equal(buckets[0].remaining, 85);
  assert.equal(buckets[1].window, "weekly");
  assert.equal(buckets[1].used, 73);
  assert.equal(buckets[2].window, "weekly-sonnet");
});

test("fetchClaudeQuota rejects request-body credentials", async () => {
  await assert.rejects(
    fetchClaudeQuota({ credential: "oauth-secret", accountID: "self_hosted" }),
    /Claude Code hosted credential refresh is not supported/
  );
});
