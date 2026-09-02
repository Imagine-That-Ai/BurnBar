import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  DEPLOY_LANES,
  collectDeployLaneHealth,
  main,
} from "./deploy-lane-health.mjs";

const timestamp = "2026-09-01T00:00:00.000Z";

function successRun(id, event = "push") {
  return {
    id,
    event,
    status: "completed",
    conclusion: "success",
    created_at: timestamp,
    updated_at: timestamp,
    html_url: `https://github.com/Imagine-That-Ai/BurnBar/actions/runs/${id}`,
  };
}

function greenFixture() {
  return {
    generatedAt: timestamp,
    lanes: DEPLOY_LANES.map((definition, index) => ({
      lane: definition.lane,
      runs: [successRun(index + 1)],
    })),
    probes: {
      functionsReady: { ok: true, statusCode: 200 },
      functionsLive: { ok: true, statusCode: 200 },
      cloudRunReady: { ok: true, statusCode: 200 },
    },
  };
}

test("deploy scoreboard contains exactly the Functions and Cloud Run lanes", () => {
  assert.deepEqual(
    DEPLOY_LANES.map((definition) => definition.lane),
    ["deploy-production", "deploy-cloud-run"],
  );
});

test("offline deploy fixture is green only with both successful deploys and probes", async () => {
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(greenFixture()));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    assert.equal(report.status, "green");
    assert.equal(report.lanes.length, 2);
    assert.ok(report.lanes.every((lane) => lane.red === false));
    assert.match(report.markdown, /Automated path: red opens\/updates/u);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("missing production run and health probe are red with explicit blocker reasons", async () => {
  const report = await collectDeployLaneHealth({
    apiBase: "https://api.github.test",
    fixture: null,
    limit: 2,
    repo: null,
    token: null,
    functionsReady: "https://functions.test/ready",
    functionsLive: "https://functions.test/live",
    cloudRunReady: "https://cloud.test/ready",
  });
  assert.equal(report.status, "red");
  assert.equal(report.lanes.length, 2);
  assert.ok(report.lanes.every((lane) => lane.red === true));
  assert.ok(report.blockers.length >= 2);
  assert.match(report.markdown, /Human queue path:/u);
});

test("a successful deploy without identity metadata is red infrastructure", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [{
    id: 11,
    event: "push",
    status: "completed",
    conclusion: "success",
  }];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.red, true);
    assert.equal(functions.failureClass, "infra");
    assert.equal(functions.reasonCode, "run-metadata-missing");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("a failed deploy stays red even when public probes are healthy", async () => {
  const fixture = greenFixture();
  fixture.lanes[1].runs = [{
    ...successRun(9),
    conclusion: "failure",
  }, successRun(8)];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 4,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const cloudRun = report.lanes.find((lane) => lane.lane === "deploy-cloud-run");
    assert.equal(cloudRun.red, true);
    assert.equal(cloudRun.failureClass, "budget");
    assert.equal(cloudRun.reasonCode, "budget-failed");
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("dry-run history is excluded without hiding the latest real deploy", async () => {
  const fixture = greenFixture();
  fixture.lanes[0].runs = [
    {
      ...successRun(50, "2026-09-03T00:00:00.000Z"),
      event: "workflow_dispatch",
      display_title: "release-control/deploy-production/dry-run/v1.0.0",
    },
    {
      ...successRun(49, "2026-09-02T00:00:00.000Z"),
      event: "push",
    },
  ];
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: fixturePath,
      limit: 1,
      repo: null,
      token: null,
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    const functions = report.lanes.find((lane) => lane.lane === "deploy-production");
    assert.equal(functions.red, false);
    assert.equal(functions.run_id, 49);
  } finally {
    await rm(tempDirectory, { recursive: true, force: true });
  }
});

test("live mode queries both deploy workflow events and health endpoints", async () => {
  const originalFetch = globalThis.fetch;
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(String(url));
    if (String(url).includes("/actions/workflows/")) {
      return new Response(JSON.stringify({ workflow_runs: [successRun(100)] }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    const body = String(url).includes("functions.test/ready")
      ? { status: "ready" }
      : String(url).includes("functions.test/live")
        ? { status: "alive" }
        : { ok: true };
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  try {
    const report = await collectDeployLaneHealth({
      apiBase: "https://api.github.test",
      fixture: null,
      limit: 2,
      repo: "Imagine-That-Ai/BurnBar",
      token: "test-token",
      functionsReady: "https://functions.test/ready",
      functionsLive: "https://functions.test/live",
      cloudRunReady: "https://cloud.test/ready",
    });
    assert.equal(report.source.mode, "github");
    assert.equal(report.status, "green");
    assert.equal(requests.filter((url) => url.includes("event=push")).length, 2);
    assert.equal(requests.filter((url) => url.includes("event=workflow_dispatch")).length, 2);
    assert.equal(requests.filter((url) => url.startsWith("https://functions.test")).length, 2);
    assert.equal(requests.filter((url) => url.startsWith("https://cloud.test")).length, 1);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("CLI persists a deploy report and returns non-zero for red fixture", async () => {
  const fixture = greenFixture();
  fixture.probes.cloudRunReady = { ok: false, statusCode: 503, error: "service unavailable" };
  const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "openburnbar-deploy-health-"));
  try {
    const fixturePath = path.join(tempDirectory, "fixture.json");
    const outputPath = path.join(tempDirectory, "deploy-lane-health.json");
    await writeFile(fixturePath, JSON.stringify(fixture));
    const report = await main(["--fixture", fixturePath, "--out", outputPath]);
    assert.equal(report.status, "red");
    assert.equal(JSON.parse(await readFile(outputPath, "utf8")).lanes.length, 2);
  } finally {
    process.exitCode = 0;
    await rm(tempDirectory, { recursive: true, force: true });
  }
});
