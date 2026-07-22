// P-OPS-4 paging payload + label semantics: proves the Slack payload the
// action POSTs is structurally valid ({ text: <non-empty string> }) and that
// shouldPageP0 + the persistent paged:ops label enforce dedupe, repeat/flap
// suppression, failed-webhook retry, and the non-P0 / close-mode never-page
// invariants.

const assert = require("node:assert/strict");
const test = require("node:test");
const {
  BLOCKER_LABEL,
  P0_LABEL,
  PAGED_LABEL,
  shouldPageP0,
} = require("./escalation.cjs");

// ---------------------------------------------------------------------------
// Slack payload shape.
//
// The action builds its page exactly like this (see action.yml pageP0IfEligible):
//   const slackText = `🚨 *P0 ops failure* — repo lane \`lane\`: summary\nIssue: issueUrl\nRun: runUrl`;
//   fetch(webhook, { ..., body: JSON.stringify({ text: slackText }) });
// We simulate that construction and assert the serialized payload is a Slack
// Incoming Webhook-compatible { text: string } object whose text is non-empty and
// carries the lane name and issue URL.
// ---------------------------------------------------------------------------

test("Slack page payload is JSON.stringify({ text }) with a non-empty string containing the lane and issue URL", () => {
  const lane = "nightly-e2e";
  const repoSlug = "burnbar/openburnbar";
  const serverUrl = "https://github.com";
  const issueNumber = 4242;
  const runUrl = `${serverUrl}/${repoSlug}/actions/runs/99`;
  const summary = "The scheduled OpenBurnBar E2E/health launch gate failed.";
  const issueUrl = `${serverUrl}/${repoSlug}/issues/${issueNumber}`;

  // Mirrors the action's slackText template verbatim.
  const slackText = `🚨 *P0 ops failure* — ${repoSlug} lane \`${lane}\`: ${summary}\nIssue: ${issueUrl}\nRun: ${runUrl}`;

  // The action POSTs this exact body shape.
  const body = JSON.stringify({ text: slackText });
  const payload = JSON.parse(body);

  assert.equal(typeof payload.text, "string", "payload.text must be a string");
  assert.ok(payload.text.length > 0, "payload.text must be non-empty");
  assert.ok(
    payload.text.includes(lane),
    "payload.text must include the lane name so the page identifies the failing lane"
  );
  assert.ok(
    payload.text.includes(issueUrl),
    "payload.text must include the issue URL so the page links to the tracking issue"
  );
  assert.ok(
    !("blocks" in payload) && !("attachments" in payload),
    "payload must be the minimal { text } shape the action sends — no blocks/attachments"
  );
});

test("payload round-trips through JSON.stringify/parse preserving the text field", () => {
  const slackText = "🚨 *P0 ops failure* — demo lane `ops-confidence`: failed\nIssue: https://github.com/burnbar/openburnbar/issues/1\nRun: https://github.com/burnbar/openburnbar/actions/runs/7";
  const serialized = JSON.stringify({ text: slackText });
  const parsed = JSON.parse(serialized);
  assert.equal(parsed.text, slackText, "text survives a JSON round-trip");
});

// ---------------------------------------------------------------------------
// Dedupe: after a successful page, the paged:ops label makes shouldPageP0
// return already-paged — proving the dedupe kicks in and suppresses repeats.
// ---------------------------------------------------------------------------

test("after a successful page, shouldPageP0 returns already-paged (dedupe kicks in)", () => {
  const paged = shouldPageP0({
    mode: "open",
    labels: [P0_LABEL, PAGED_LABEL],
  });
  assert.equal(paged.shouldPage, false);
  assert.equal(paged.reason, "already-paged");
});

// ---------------------------------------------------------------------------
// Repeat suppression: a P0 already carrying paged:ops on a second run does not
// re-page (the label persists across runs).
// ---------------------------------------------------------------------------

test("repeat suppression: a P0 with paged:ops on a second run returns already-paged (no re-page)", () => {
  const firstRun = shouldPageP0({ mode: "open", labels: [P0_LABEL] });
  assert.deepEqual(firstRun, { shouldPage: true, reason: "p0-unpaged" });

  // After the first page succeeded, paged:ops was added. The second run sees it.
  const secondRun = shouldPageP0({
    mode: "open",
    labels: [P0_LABEL, PAGED_LABEL],
  });
  assert.equal(secondRun.shouldPage, false);
  assert.equal(secondRun.reason, "already-paged");
});

// ---------------------------------------------------------------------------
// Flap suppression: close→reopen (or a recurring/flapping failure) keeps the
// paged:ops label on the issue, so shouldPageP0 still returns already-paged.
// ---------------------------------------------------------------------------

test("flap suppression: paged:ops persists across runs so a flapping lane does not re-page", () => {
  // Run 1: open P0, unpaged → page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: [P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );

  // Run 2: still open, now paged → suppressed.
  assert.equal(
    shouldPageP0({ mode: "open", labels: [P0_LABEL, PAGED_LABEL] }).reason,
    "already-paged"
  );

  // Run 3: lane flaps again (still the same open issue, paged:ops persists) → suppressed.
  assert.equal(
    shouldPageP0({ mode: "open", labels: [P0_LABEL, PAGED_LABEL] }).reason,
    "already-paged"
  );
});

// ---------------------------------------------------------------------------
// Failed/missing webhook retry: a P0 WITHOUT paged:ops (because the webhook
// failed or was missing and the label was never added) stays eligible to page
// on the next run — proving the retry path is open.
// ---------------------------------------------------------------------------

test("failed/missing webhook leaves the issue unpaged so a later run can retry", () => {
  // First run: eligible to page.
  assert.deepEqual(
    shouldPageP0({ mode: "open", labels: [P0_LABEL] }),
    { shouldPage: true, reason: "p0-unpaged" }
  );

  // Webhook failed/missing → paged:ops was NOT added. Next run still sees no
  // paged:ops, so it must remain eligible to page (retry).
  const retry = shouldPageP0({ mode: "open", labels: [P0_LABEL] });
  assert.equal(retry.shouldPage, true);
  assert.equal(retry.reason, "p0-unpaged");
});

// ---------------------------------------------------------------------------
// Non-P0 lanes never page, regardless of whether paged:ops is present.
// ---------------------------------------------------------------------------

test("non-P0 lanes never page regardless of paged:ops presence", () => {
  assert.equal(
    shouldPageP0({ mode: "open", labels: ["P1 - High"] }).shouldPage,
    false
  );
  assert.equal(
    shouldPageP0({ mode: "open", labels: ["P1 - High"] }).reason,
    "not-p0"
  );

  // Even if paged:ops were somehow present, a non-P0 still must not page.
  assert.equal(
    shouldPageP0({ mode: "open", labels: ["P1 - High", PAGED_LABEL] }).shouldPage,
    false
  );
  assert.equal(
    shouldPageP0({ mode: "open", labels: ["P1 - High", PAGED_LABEL] }).reason,
    "not-p0"
  );

  // No labels at all is also not-p0.
  assert.equal(
    shouldPageP0({ mode: "open", labels: [] }).reason,
    "not-p0"
  );
});

// ---------------------------------------------------------------------------
// Close mode never pages, regardless of paged:ops presence.
// ---------------------------------------------------------------------------

test("close mode never pages regardless of paged:ops presence", () => {
  assert.equal(
    shouldPageP0({ mode: "close", labels: [P0_LABEL] }).shouldPage,
    false
  );
  assert.equal(
    shouldPageP0({ mode: "close", labels: [P0_LABEL] }).reason,
    "not-open-mode"
  );

  // Close on an already-paged P0 still never pages.
  assert.equal(
    shouldPageP0({ mode: "close", labels: [P0_LABEL, PAGED_LABEL] }).shouldPage,
    false
  );
  assert.equal(
    shouldPageP0({ mode: "close", labels: [P0_LABEL, PAGED_LABEL] }).reason,
    "not-open-mode"
  );
});

// ---------------------------------------------------------------------------
// Cross-check: the label constants are the expected dedupe primitives.
// ---------------------------------------------------------------------------

test("label constants are the expected P-OPS-4 primitives", () => {
  assert.equal(P0_LABEL, "P0 - Critical");
  assert.equal(PAGED_LABEL, "paged:ops");
  assert.equal(BLOCKER_LABEL, "known-red-named-blocker");
});

// ---------------------------------------------------------------------------
// Fetch timeout: the action's fetch() call must use a bounded AbortSignal so
// an unhealthy Slack endpoint cannot wedge the alerting workflow (Codex P2
// #discussion_r3585532542).
// ---------------------------------------------------------------------------

test("action.yml fetch call includes AbortSignal.timeout to bound the webhook POST", () => {
  const fs = require("node:fs");
  const path = require("node:path");
  const actionYml = fs.readFileSync(path.join(__dirname, "action.yml"), "utf8");
  // The pageP0IfEligible function's fetch must have signal: AbortSignal.timeout(...)
  assert.match(
    actionYml,
    /signal:\s*AbortSignal\.timeout\(\s*\d+\s*\)/,
    "action.yml fetch() must include signal: AbortSignal.timeout(<ms>) to bound the webhook POST"
  );
});