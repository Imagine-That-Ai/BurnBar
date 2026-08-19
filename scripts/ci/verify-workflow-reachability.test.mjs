import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  auditWorkflows,
  pathCovered,
  scriptsReferencedBy,
  transitiveLocalImports,
} from "./verify-workflow-reachability.mjs";
import {
  hasStatusCheckFunction,
  readWorkflow,
  transitiveNeeds,
} from "../lib/github-workflow.mjs";

/** Build a throwaway repo root so the gate can be exercised against fixtures. */
function fixtureRoot(files) {
  const root = mkdtempSync(join(tmpdir(), "workflow-reachability-"));
  for (const [path, contents] of Object.entries(files)) {
    const absolute = join(root, path);
    mkdirSync(join(absolute, ".."), { recursive: true });
    writeFileSync(absolute, contents);
  }
  return root;
}

const SKIP_PROPAGATION_WORKFLOW = `name: Fixture
on:
  push:
    branches: [main]
jobs:
  gate:
    if: \${{ inputs.rollback == true }}
    runs-on: ubuntu-latest
    steps:
      - run: echo gate
  build:
    needs: gate
    if: \${{ always() }}
    runs-on: ubuntu-latest
    steps:
      - run: echo build
  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo deploy
`;

test("the August outage reproduces: deploy inherits a skip across an always() job", () => {
  // gate skips on every normal run; build survives via always(); deploy has no
  // status-check function, so GitHub never schedules it. This is exactly the
  // shape that stopped burnbar.ai deploying for a month.
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": SKIP_PROPAGATION_WORKFLOW,
  });
  try {
    const findings = auditWorkflows(root);
    const deploy = findings.find(
      (finding) => finding.kind === "skip-propagation" && finding.job === "deploy",
    );
    assert.ok(deploy, "deploy must be flagged");
    assert.match(deploy.detail, /inherits a skip from \[gate\]/u);
    // `build` carries always(), so it is not itself a finding.
    assert.equal(
      findings.some((finding) => finding.job === "build"),
      false,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("adding a status-check function clears the finding", () => {
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": SKIP_PROPAGATION_WORKFLOW.replace(
      "  deploy:\n    needs: build\n",
      "  deploy:\n    needs: build\n    if: ${{ !cancelled() && needs.build.result == 'success' }}\n",
    ),
  });
  try {
    assert.deepEqual(
      auditWorkflows(root).filter((finding) => finding.kind === "skip-propagation"),
      [],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a governed declaration clears the finding, an empty reason does not", () => {
  const governance = (reason) =>
    JSON.stringify({
      skipPropagation: [{ workflow: "fixture.yml", job: "deploy", reason }],
    });
  const withReason = fixtureRoot({
    ".github/workflows/fixture.yml": SKIP_PROPAGATION_WORKFLOW,
    "governance/workflow-reachability.json": governance(
      "Intended: the deploy lane genuinely does not apply when the gate skips.",
    ),
  });
  const withoutReason = fixtureRoot({
    ".github/workflows/fixture.yml": SKIP_PROPAGATION_WORKFLOW,
    "governance/workflow-reachability.json": governance("n/a"),
  });
  try {
    assert.equal(
      auditWorkflows(withReason).filter((f) => f.kind === "skip-propagation").length,
      0,
    );
    // A token reason must not buy an exemption.
    assert.equal(
      auditWorkflows(withoutReason).filter((f) => f.kind === "skip-propagation")
        .length,
      1,
    );
  } finally {
    rmSync(withReason, { recursive: true, force: true });
    rmSync(withoutReason, { recursive: true, force: true });
  }
});

const PATHS_WORKFLOW = `name: Fixture Deploy
on:
  push:
    branches: [main]
    paths:
      - "scripts/ci/entry.mjs"
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - run: node scripts/ci/entry.mjs --go
`;

test("a transitively imported module outside the path filter is flagged", () => {
  // entry.mjs is covered; the helper it imports is not. Editing the helper
  // therefore fixes nothing, because the workflow never triggers — the exact
  // reason the Firebase Hosting name fix merged and deployed nothing.
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": PATHS_WORKFLOW,
    "scripts/ci/entry.mjs": 'import { go } from "../lib/helper.mjs";\ngo();\n',
    "scripts/lib/helper.mjs": "export const go = () => {};\n",
  });
  try {
    const findings = auditWorkflows(root).filter(
      (finding) => finding.kind === "paths-coverage",
    );
    assert.deepEqual(
      findings.map((finding) => finding.path),
      ["scripts/lib/helper.mjs"],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("covering the helper in the path filter clears the finding", () => {
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": PATHS_WORKFLOW.replace(
      '      - "scripts/ci/entry.mjs"\n',
      '      - "scripts/ci/entry.mjs"\n      - "scripts/lib/helper.mjs"\n',
    ),
    "scripts/ci/entry.mjs": 'import { go } from "../lib/helper.mjs";\ngo();\n',
    "scripts/lib/helper.mjs": "export const go = () => {};\n",
  });
  try {
    assert.deepEqual(
      auditWorkflows(root).filter((finding) => finding.kind === "paths-coverage"),
      [],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("workflows without a push path filter are not path-audited", () => {
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": PATHS_WORKFLOW.replace(
      '    paths:\n      - "scripts/ci/entry.mjs"\n',
      "",
    ),
    "scripts/ci/entry.mjs": 'import { go } from "../lib/helper.mjs";\ngo();\n',
    "scripts/lib/helper.mjs": "export const go = () => {};\n",
  });
  try {
    assert.deepEqual(
      auditWorkflows(root).filter((finding) => finding.kind === "paths-coverage"),
      [],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("pathCovered honours the glob shapes GitHub actually accepts", () => {
  assert.equal(pathCovered("scripts/lib/a.mjs", ["scripts/lib/a.mjs"]), true);
  assert.equal(pathCovered("scripts/lib/a.mjs", ["scripts/**"]), true);
  assert.equal(pathCovered("scripts/lib/a.mjs", ["scripts/*"]), false);
  assert.equal(pathCovered("scripts/a.mjs", ["scripts/*"]), true);
  assert.equal(pathCovered("scripts/lib/a.mjs", [".github/workflows/*.yml"]), false);
  assert.equal(
    pathCovered(".github/workflows/deploy.yml", [".github/workflows/*.yml"]),
    true,
  );
});

test("scriptsReferencedBy finds invocations and ignores prose", () => {
  assert.deepEqual(
    scriptsReferencedBy("node scripts/ci/a.mjs --flag\nbash scripts/lib/b.sh"),
    ["scripts/ci/a.mjs", "scripts/lib/b.sh"],
  );
  // A path embedded in a longer token is not an invocation.
  assert.deepEqual(scriptsReferencedBy("see docs/scripts/ci/a.mjs"), []);
  assert.deepEqual(scriptsReferencedBy(undefined), []);
});

test("transitiveLocalImports walks the local graph and stops at package imports", () => {
  const root = fixtureRoot({
    "scripts/ci/a.mjs": 'import "./b.mjs";\nimport "node:fs";\nimport "yaml";\n',
    "scripts/ci/b.mjs": 'import "../lib/c.mjs";\n',
    "scripts/lib/c.mjs": "export const c = 1;\n",
  });
  try {
    assert.deepEqual([...transitiveLocalImports("scripts/ci/a.mjs", root)].sort(), [
      "scripts/ci/a.mjs",
      "scripts/ci/b.mjs",
      "scripts/lib/c.mjs",
    ]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("the parser reads block-scalar conditions without their indicator", () => {
  const root = fixtureRoot({
    ".github/workflows/fixture.yml": `name: Fixture
on:
  push:
    branches: [main]
jobs:
  a:
    if: >-
      \${{ needs.b.result == 'success'
          && github.event_name == 'push' }}
    needs: [b]
    environment: production
    runs-on: ubuntu-latest
    steps:
      - name: step # trailing comment
        run: echo hi
  b:
    runs-on: ubuntu-latest
    steps:
      - run: echo b
`,
  });
  try {
    const workflow = readWorkflow(join(root, ".github/workflows/fixture.yml"));
    assert.equal(workflow.name, "Fixture");
    assert.equal(workflow.jobs.a.environment, "production");
    assert.deepEqual(workflow.jobs.a.needs, ["b"]);
    assert.equal(workflow.jobs.a.if.startsWith(">-"), false);
    assert.match(workflow.jobs.a.if, /^\$\{\{ needs\.b\.result/u);
    assert.equal(workflow.jobs.a.steps[0].name, "step");
    assert.deepEqual([...transitiveNeeds(workflow.jobs, "a")], ["b"]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("hasStatusCheckFunction recognises the guards GitHub honours", () => {
  assert.equal(hasStatusCheckFunction("${{ always() }}"), true);
  assert.equal(hasStatusCheckFunction("${{ !cancelled() && x }}"), true);
  assert.equal(hasStatusCheckFunction("${{ ! cancelled() }}"), true);
  assert.equal(hasStatusCheckFunction("${{ success() }}"), true);
  assert.equal(hasStatusCheckFunction("${{ needs.a.result == 'success' }}"), false);
  assert.equal(hasStatusCheckFunction(undefined), false);
});

test("the repository itself satisfies the gate", () => {
  // Guards the committed baseline: a new violation must be fixed or declared.
  assert.deepEqual(auditWorkflows(), []);
});
