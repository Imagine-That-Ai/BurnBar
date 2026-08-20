// P-OPS-4 paging wiring: static verification that every workflow caller wires
// the `paging-slack-webhook` input on its `mode: open` calls to the
// ops-failure-issue composite action, and that `mode: close` calls never page.
//
// This is a pure static read — no network, no GitHub API. It parses the raw
// workflow YAML line-by-line to extract each
// `uses: ./.github/actions/ops-failure-issue` step block and asserts the
// paging input is present on open and absent on close.

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const ACTION_DIR = __dirname;
const WORKFLOWS_DIR = path.resolve(ACTION_DIR, "..", "..", "workflows");
const ACTION_YML = path.join(ACTION_DIR, "action.yml");

// Every workflow that calls ops-failure-issue with mode: open. Each maps to
// every exact lane value its open calls declare (used as a cross-check that we
// matched every block independently).
const OPEN_WORKFLOWS = [
  { file: "deploy-cloud-run.yml", lanes: ["deploy-cloud-run"] },
  { file: "deploy-firestore.yml", lanes: ["deploy-firestore"] },
  { file: "deploy-hosting.yml", lanes: ["deploy-hosting"] },
  { file: "deploy-production.yml", lanes: ["deploy-production"] },
  { file: "linux-nightly.yml", lanes: ["linux-nightly"] },
  { file: "nightly-dast-sandbox.yml", lanes: ["nightly-sandbox"] },
  { file: "nightly-e2e.yml", lanes: ["nightly-e2e"] },
  { file: "ops-confidence.yml", lanes: ["ops-confidence", "deploy-freshness"] },
];

const ACTION_USES = "./.github/actions/ops-failure-issue";
const PAGING_LINE =
  "paging-slack-webhook: ${{ secrets.OPS_PAGING_SLACK_WEBHOOK }}";

/**
 * Read a workflow file's lines.
 */
function readLines(relFile) {
  const abs = path.join(WORKFLOWS_DIR, relFile);
  const content = fs.readFileSync(abs, "utf8");
  return content.split(/\r?\n/);
}

/**
 * Extract every ops-failure-issue step block from a workflow.
 *
 * A step block begins at a `uses: ./.github/actions/ops-failure-issue` line
 * (indented 8 spaces under a `      - ` list item) and extends through every
 * following line that is blank or indented at least 8 spaces — stopping at the
 * next list item / job key (indent < 8) or EOF. This captures the full `with:`
 * map including folded scalars like `summary: >-`.
 *
 * Returns an array of { mode, lane, block } where block is the joined step text.
 */
function extractActionBlocks(relFile) {
  const lines = readLines(relFile);
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.includes(ACTION_USES)) continue;

    // Capture the step body: this line + following lines while blank or
    // indented >= 8 spaces (deeper than the 6-space list-item dash).
    const body = [line];
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j];
      if (next.trim() === "") {
        body.push(next);
        continue;
      }
      const indent = next.length - next.trimStart().length;
      if (indent < 8) break;
      body.push(next);
    }
    const block = body.join("\n");

    // Determine the mode and lane from keys whose first token after indentation
    // is `mode:` or `lane:`.
    let mode = null;
    let lane = null;
    for (const bodyLine of body) {
      const modeMatch = bodyLine.match(/^\s+mode:\s*(\S+)\s*$/);
      if (modeMatch) mode = modeMatch[1];

      const laneMatch = bodyLine.match(/^\s+lane:\s*(\S+)\s*$/);
      if (laneMatch) lane = laneMatch[1];
    }
    blocks.push({ mode, lane, block });
  }
  return blocks;
}

/**
 * Extract one top-level workflow job, including its steps but excluding the
 * next job. Assertions below exercise alert behavior inside the result jobs,
 * not unrelated occurrences elsewhere in the workflow.
 */
function extractJob(relFile, jobName) {
  const source = readLines(relFile).join("\n");
  const start = source.indexOf(`  ${jobName}:\n`);
  assert.notEqual(start, -1, `${relFile} must define job ${jobName}`);
  const remainder = source.slice(start + 2);
  const next = remainder.search(/^  [A-Za-z0-9_-]+:\n/m);
  return next === -1
    ? source.slice(start)
    : source.slice(start, start + 2 + next);
}

/** Extract a named step from an already isolated job. */
function extractStep(job, stepName) {
  const marker = `      - name: ${stepName}\n`;
  const start = job.indexOf(marker);
  assert.notEqual(start, -1, `job must define step ${stepName}`);
  const remainder = job.slice(start + marker.length);
  const next = remainder.search(/^      - /m);
  return next === -1
    ? job.slice(start)
    : job.slice(start, start + marker.length + next);
}

/** Return the workflow preamble above jobs, where triggers/concurrency live. */
function workflowPreamble(relFile) {
  const source = readLines(relFile).join("\n");
  const jobs = source.indexOf("\njobs:\n");
  assert.notEqual(jobs, -1, `${relFile} must define jobs`);
  return source.slice(0, jobs);
}

// ---------------------------------------------------------------------------
// Per-workflow wiring: open must page, close must not.
// ---------------------------------------------------------------------------

for (const { file, lanes } of OPEN_WORKFLOWS) {
  test(`${file} wires paging-slack-webhook on every mode: open and omits it on mode: close`, () => {
    const blocks = extractActionBlocks(file);
    assert.ok(
      blocks.length > 0,
      `${file} must call the ops-failure-issue action at least once`,
    );

    const openBlocks = blocks.filter((b) => b.mode === "open");
    const closeBlocks = blocks.filter((b) => b.mode === "close");

    assert.equal(
      openBlocks.length,
      lanes.length,
      `${file} must have exactly ${lanes.length} mode: open call(s) to ops-failure-issue`,
    );

    // Validate every open invocation independently: each must page and use one
    // of this workflow's explicitly expected lanes.
    for (const { lane, block } of openBlocks) {
      assert.ok(
        block.includes(PAGING_LINE),
        `${file} mode: open block must wire paging-slack-webhook to the repo secret:\n${block}`,
      );
      assert.ok(
        lanes.includes(lane),
        `${file} mode: open block must declare one of the exact expected lanes (${lanes.join(", ")}):\n${block}`,
      );
    }

    assert.deepEqual(
      openBlocks.map(({ lane }) => lane).sort(),
      [...lanes].sort(),
      `${file} mode: open calls must declare exactly the expected lanes`,
    );

    // Close never pages: no close block may carry the paging input.
    for (const { block } of closeBlocks) {
      assert.ok(
        !/^\s+paging-slack-webhook:\s/m.test(block),
        `${file} mode: close block must NOT wire paging-slack-webhook (close never pages):\n${block}`,
      );
    }
  });
}

test("Functions result pages any failed deploy stage and closes only after full recovery", () => {
  const job = extractJob("deploy-production.yml", "functions-result");
  assert.match(
    job,
    /^    needs: \[prepare-functions-deploy, deploy-functions, functions-health-gate\]$/m,
  );
  assert.match(
    job,
    /^    if: \$\{\{ always\(\) && !inputs\.dry_run \}\}$/m,
    "the result job must run after failed or skipped non-dry-run stages",
  );

  const open = extractStep(
    job,
    "Record Functions deploy or health failure (per-lane dedupe; page once)",
  );
  for (const dependency of [
    "prepare-functions-deploy",
    "deploy-functions",
    "functions-health-gate",
  ]) {
    assert.match(
      open,
      new RegExp(`needs\\.${dependency}\\.result != 'success'`),
      `${dependency} failure must open and page the Functions incident`,
    );
  }
  assert.match(open, /^          mode: open$/m);
  assert.match(open, /^          lane: deploy-production$/m);
  assert.match(
    open,
    /^          title-prefix: Production Functions deploy or health gate failed$/m,
  );
  assert.match(
    open,
    /^          paging-slack-webhook: \$\{\{ secrets\.OPS_PAGING_SLACK_WEBHOOK \}\}$/m,
  );

  const close = extractStep(
    job,
    "Close resolved Functions deploy failure issue",
  );
  for (const dependency of [
    "prepare-functions-deploy",
    "deploy-functions",
    "functions-health-gate",
  ]) {
    assert.match(
      close,
      new RegExp(`needs\\.${dependency}\\.result == 'success'`),
      `${dependency} must recover before the Functions incident closes`,
    );
  }
  assert.match(close, /^          mode: close$/m);
  assert.match(close, /^          lane: deploy-production$/m);
  assert.match(
    close,
    /^          title-prefix: Production Functions deploy or health gate failed$/m,
  );
});

test("Hosting opens and closes its incident for tag and manual non-dry-run outcomes", () => {
  const preamble = workflowPreamble("deploy-hosting.yml");
  assert.match(preamble, /^    tags: \["v\*"\]$/m);
  assert.match(preamble, /^  workflow_dispatch:$/m);

  const job = extractJob("deploy-hosting.yml", "hosting-smoke-result");
  assert.match(
    job,
    /^    if: \$\{\{ always\(\) && \(github\.event_name != 'workflow_dispatch' \|\| inputs\.dry_run != true\) \}\}$/m,
  );
  const open = extractStep(
    job,
    "Record hosting deploy failure (per-lane dedupe; comment, never silent-skip)",
  );
  const close = extractStep(job, "Close resolved hosting deploy failure issue");
  assert.match(open, /^        if: failure\(\)$/m);
  assert.match(close, /^        if: success\(\)$/m);
  assert.doesNotMatch(open, /github\.ref|refs\/heads\/main/);
  assert.doesNotMatch(close, /github\.ref|refs\/heads\/main/);
});

test("Firestore manual production failures open an incident and successful recovery closes it", () => {
  const preamble = workflowPreamble("deploy-firestore.yml");
  assert.match(preamble, /^  workflow_dispatch:$/m);

  const job = extractJob("deploy-firestore.yml", "firestore-result");
  assert.match(
    job,
    /^    if: \$\{\{ always\(\) && \(github\.event_name != 'workflow_dispatch' \|\| github\.event\.inputs\.dry_run != 'true'\) \}\}$/m,
    "manual non-dry-run deploys must reach the result job",
  );
  const open = extractStep(
    job,
    "Record Firestore deploy failure (per-lane dedupe; comment, never silent-skip)",
  );
  const close = extractStep(
    job,
    "Close resolved Firestore deploy failure issue",
  );
  assert.match(open, /^        if: failure\(\)$/m);
  assert.match(open, /^          mode: open$/m);
  assert.match(close, /^        if: success\(\)$/m);
  assert.match(close, /^          mode: close$/m);
});

test("Firestore serializes every trigger through one project-scoped concurrency group", () => {
  const preamble = workflowPreamble("deploy-firestore.yml");
  for (const trigger of ["push", "schedule", "workflow_dispatch"]) {
    assert.match(preamble, new RegExp(`^  ${trigger}:`, "m"));
  }
  const groupLines = preamble.match(/^  group: .*$/gm) || [];
  assert.deepEqual(groupLines, [
    "  group: deploy-firestore-production-burnbar",
  ]);
  assert.doesNotMatch(groupLines[0], /\$\{\{/);
  assert.match(preamble, /^  cancel-in-progress: false$/m);
});

// ---------------------------------------------------------------------------
// Sanity: every open caller is accounted for (no missing/extra wiring).
// ---------------------------------------------------------------------------

test("exactly the 8 expected workflows call ops-failure-issue with mode: open", () => {
  const allYml = fs
    .readdirSync(WORKFLOWS_DIR)
    .filter((f) => f.endsWith(".yml"));

  const openCallers = [];
  for (const f of allYml) {
    const blocks = extractActionBlocks(f);
    if (blocks.some((b) => b.mode === "open")) {
      openCallers.push(f);
    }
  }

  const expected = OPEN_WORKFLOWS.map((w) => w.file).sort();
  const actual = openCallers.sort();
  assert.deepEqual(
    actual,
    expected,
    "the set of workflows with a mode: open call to ops-failure-issue must be exactly the 8 P-OPS-4 paging lanes",
  );
});

// ---------------------------------------------------------------------------
// action.yml: the paging-slack-webhook input must be wired to the
// OPS_PAGING_SLACK_WEBHOOK env var on the composite step.
// ---------------------------------------------------------------------------

test("action.yml wires paging-slack-webhook input to OPS_PAGING_SLACK_WEBHOOK env var", () => {
  const content = fs.readFileSync(ACTION_YML, "utf8");
  assert.ok(
    /OPS_PAGING_SLACK_WEBHOOK:\s*\$\{\{\s*inputs\.paging-slack-webhook\s*\}\}/.test(
      content,
    ),
    "action.yml must map the paging-slack-webhook input to the OPS_PAGING_SLACK_WEBHOOK env var on the composite step",
  );
  assert.ok(
    /^\s+paging-slack-webhook:\s*$/m.test(content) &&
      /required:\s*false/.test(content) &&
      /default:\s*""/.test(content),
    "action.yml must declare paging-slack-webhook as an optional input defaulting to empty",
  );
});
