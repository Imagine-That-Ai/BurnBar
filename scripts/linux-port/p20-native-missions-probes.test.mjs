import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP20NativeMissionsProbes } from "./run-p20-native-missions-probes.mjs";

const MARKER = "p20-fedcba0987654321";
const IDENTITY = {
  environmentId: "ubuntu-24.04-gnome-x11-aarch64",
  targetHead: "a".repeat(40),
  candidateRunId: "202020",
  candidateArtifactDigest: `sha256:${"b".repeat(64)}`,
  packageVersion: "1.2.3",
  manifestSha256: "c".repeat(64),
  manifestSignatureSha256: "d".repeat(64),
  compositor: "Mutter",
};
function fixture() {
  const base = path.join(process.cwd(), ".tmp/p20-native-probe-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  fs.chmodSync(root, 0o700);
  const rawOutputDir = path.join(root, "raw");
  const supportDir = path.join(root, "support");
  const homeDir = path.join(root, "home");
  for (const directory of [rawOutputDir, supportDir, homeDir])
    fs.mkdirSync(directory, { mode: 0o700 });
  const tokenFile = path.join(supportDir, "token");
  fs.writeFileSync(tokenFile, `${"e".repeat(64)}\n`, { mode: 0o600 });
  return {
    root,
    options: {
      rawOutputDir,
      supportDir,
      homeDir,
      tokenFile,
      socketPath: path.join(supportDir, "daemon.sock"),
      indexDatabase: path.join(supportDir, "index.sqlite"),
      ...IDENTITY,
    },
  };
}
function dependencies(options, failMethod = null) {
  let project;
  let mission;
  let question;
  let selected = false;
  let launches = 0;
  let restarts = 0;
  const history = [];
  const rpc = async (method, request) => {
    if (method === failMethod) throw new Error(`forced ${method}`);
    if (method === "daemon.controller.project.upsert") {
      project = structuredClone(request.project);
      return { project };
    }
    if (method === "daemon.mission.create") {
      mission = {
        id: `mission:${MARKER}`,
        projectSlug: request.projectSlug,
        title: request.title,
        summary: request.summary,
        status: "awaiting_approval",
        approval: { approved: false },
        packets: [],
        results: [],
        prLinkage: null,
      };
      history.push({ id: "created" });
      return { mission: structuredClone(mission) };
    }
    if (method === "daemon.mission.list")
      return { missions: mission ? [structuredClone(mission)] : [] };
    if (method === "daemon.mission.get")
      return { mission: structuredClone(mission) };
    if (method === "daemon.mission.packet.dispatch") {
      mission.status = "in_progress";
      mission.packets.push(structuredClone(request.packet));
      history.push({ id: "packet" });
      return { mission: structuredClone(mission) };
    }
    if (method === "daemon.mission.result.record") {
      mission.results.push(structuredClone(request.result));
      mission.prLinkage = structuredClone(request.result.prLinkage);
      history.push({ id: "result" });
      return { mission: structuredClone(mission) };
    }
    if (method === "daemon.mission.health")
      return {
        missionID: mission.id,
        health: { status: "healthy", detail: "active" },
        history: structuredClone(history),
      };
    if (method === "daemon.question.create") {
      question = structuredClone(request.question);
      return { question: structuredClone(question) };
    }
    if (method === "daemon.question.list")
      return { questions: question ? [structuredClone(question)] : [] };
    throw new Error(`unexpected RPC ${method}`);
  };
  const names = () => [
    { name: "Missions" },
    { name: "Missions lane" },
    ...(mission
      ? [
          { name: mission.title },
          {
            name:
              mission.status === "cancelled"
                ? "Cancelled"
                : mission.status === "approved"
                  ? "Approved"
                  : "Pending approvals",
          },
          { name: `Approve ${mission.title}` },
          { name: "Inspect logs" },
          { name: "Cancel mission" },
          { name: "Confirm cancel" },
        ]
      : []),
    ...(question
      ? [
          { name: question.title },
          { name: question.suggestedOptions[0].title },
          { name: "Submit answer" },
        ]
      : []),
    { name: "Packets / tasks" },
    { name: "Results / evidence" },
    { name: "Controller history" },
    { name: `evidence:${MARKER}` },
  ];
  const ui = {
    async launch() {
      launches += 1;
      return { pid: 2000 + launches };
    },
    snapshot() {
      return { nodes: names() };
    },
    screenshot(name) {
      fs.writeFileSync(
        path.join(options.rawOutputDir, name),
        Buffer.alloc(2048, launches),
      );
    },
    async activate(name) {
      if (name.startsWith("Approve ")) {
        mission.status = "approved";
        mission.approval = { approved: true };
        history.push({ id: "approved" });
      } else if (name.includes(MARKER) && name.startsWith("Proceed"))
        selected = true;
      else if (name === "Submit answer" && selected) {
        question.status = "answered";
        question.latestAnswer = {
          answer: `Proceed with ${MARKER}`,
          selectedOptionID: `option:${MARKER}`,
        };
      } else if (name === "Confirm cancel") mission.status = "cancelled";
      return {
        producer: "openburnbar-p20-atspi-control-v1",
        activation: { name, role: "push button", action: "click" },
      };
    },
    async stop() {},
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    marker: MARKER,
    rpc,
    ui,
    daemon: {
      async prepare() {},
      async restart() {
        restarts += 1;
      },
      async restore() {},
    },
    restarts: () => restarts,
    project: () => project,
  };
}

test("P-20 native runner proves approval, execution evidence, question, restart, and cancellation", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  try {
    const result = await runP20NativeMissionsProbes(value.options, deps);
    assert.equal(result.missionID, `mission:${MARKER}`);
    assert.equal(deps.restarts(), 1);
    const daemon = JSON.parse(
      fs.readFileSync(
        path.join(result.output, "missions-daemon-transcript.json"),
      ),
    );
    assert.equal(daemon.events.length, 12);
    assert.deepEqual(
      daemon.events.map((event) => event.phase),
      [
        "project-upserted",
        "mission-created",
        "mission-listed",
        "mission-approved-readback",
        "packet-dispatched",
        "result-recorded",
        "mission-health",
        "question-created",
        "question-answered-readback",
        "restart-mission-get",
        "restart-mission-health",
        "mission-cancelled-readback",
      ],
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "missions-ui-transcript.json")),
    );
    assert.deepEqual(
      ui.events.map((event) => event.phase),
      [
        "pending-approval",
        "approved",
        "pending-question",
        "restart-detail",
        "mission-detail",
        "cancelled",
      ],
    );
    for (const name of [
      "missions-pending.png",
      "missions-approved.png",
      "missions-question.png",
      "missions-detail.png",
      "missions-cancelled.png",
    ])
      assert.ok(fs.statSync(path.join(result.output, name)).size > 1024, name);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-20 native runner restores the daemon after a failed lifecycle RPC", async () => {
  const value = fixture();
  let restored = false;
  const deps = dependencies(value.options, "daemon.mission.result.record");
  deps.daemon.restore = async () => {
    restored = true;
  };
  try {
    await assert.rejects(
      runP20NativeMissionsProbes(value.options, deps),
      /forced daemon\.mission\.result\.record/u,
    );
    assert.equal(restored, true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
