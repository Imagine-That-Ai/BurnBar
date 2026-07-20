import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP18NativeMemoryProbes } from "./run-p18-native-memory-probes.mjs";

const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const IDENTITY = {
  targetHead: "a".repeat(40),
  candidateRunId: "181818",
  candidateArtifactDigest: `sha256:${"b".repeat(64)}`,
  packageVersion: "1.2.3",
  manifestSha256: "c".repeat(64),
  manifestSignatureSha256: "d".repeat(64),
  compositor: "Mutter",
};

function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes, { mode });
  return file;
}
function fixture() {
  const base = path.join(process.cwd(), ".tmp/p18-native-probe-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  fs.chmodSync(root, 0o700);
  const rawOutputDir = path.join(root, "raw");
  const supportDir = path.join(root, "support");
  const homeDir = path.join(root, "home");
  fs.mkdirSync(rawOutputDir, { mode: 0o700 });
  fs.mkdirSync(supportDir, { mode: 0o700 });
  fs.mkdirSync(homeDir, { mode: 0o700 });
  const tokenFile = write(
    path.join(supportDir, "token"),
    `${"e".repeat(64)}\n`,
  );
  return {
    root,
    options: {
      rawOutputDir,
      supportDir,
      homeDir,
      tokenFile,
      socketPath: path.join(supportDir, "daemon.sock"),
      indexDatabase: path.join(supportDir, "index.sqlite"),
      environmentId: ENVIRONMENT,
      ...IDENTITY,
    },
  };
}
function memoryHit(id, body, reviewStatus) {
  return {
    memoryID: id,
    projectID: "project-p18",
    bodyRedacted: body,
    snippet: body,
    reviewStatus,
  };
}
function dependencies(options, { leakQuarantine = false } = {}) {
  const state = new Map();
  let sequence = 0;
  let launches = 0;
  const audit = [];
  const auditEvent = (action, subjectID, label) => {
    const index = audit.length + 1;
    const previous = audit.at(-1)?.hash ?? null;
    const hash = String(index).repeat(64);
    audit.push({
      seq: index,
      ts: new Date(Date.now() + index).toISOString(),
      actor: "daemon",
      action,
      domain: "memory",
      projectID: "project-p18",
      subjectID,
      labels: [label],
      prevHash: previous,
      hash,
    });
    return hash;
  };
  const rpc = async (method, request) => {
    if (method === "daemon.memory.remember") {
      sequence += 1;
      const memoryID = `mem_${String(sequence + 2).repeat(32)}`;
      state.set(memoryID, { body: request.text, status: request.reviewStatus });
      return {
        traceID: `t${sequence}`,
        projectID: "project-p18",
        memoryID,
        auditHash: auditEvent(
          "memory.remember",
          memoryID,
          `review_status:${request.reviewStatus}`,
        ),
      };
    }
    if (method === "daemon.memory.review_status") {
      const row = state.get(request.memoryID);
      row.status = request.status;
      return {
        traceID: "review",
        projectID: "project-p18",
        memoryID: request.memoryID,
        status: request.status,
        auditHash: auditEvent(
          "memory.review_status",
          request.memoryID,
          `review_status:${request.status}`,
        ),
      };
    }
    if (method === "daemon.memory.forget") {
      const row = state.get(request.memoryID);
      row.status = "forgotten";
      row.body = "";
      return {
        traceID: "forget",
        projectID: "project-p18",
        memoryID: request.memoryID,
        localDeleted: true,
        cloudDeletePending: false,
        auditHash: auditEvent(
          "memory.forget",
          request.memoryID,
          "review_status:forgotten",
        ),
      };
    }
    if (method === "daemon.memory.audit_trail")
      return {
        traceID: "audit",
        projectID: "project-p18",
        events: [...audit].reverse(),
      };
    const hits = [...state]
      .filter(
        ([, row]) => request.includeQuarantined || row.status === "approved",
      )
      .filter(
        ([, row]) => request.includeForgotten || row.status !== "forgotten",
      )
      .filter(
        ([, row]) =>
          leakQuarantine ||
          request.includeQuarantined ||
          row.status !== "quarantined",
      )
      .filter(
        ([, row]) => request.includeQuarantined || row.status !== "rejected",
      )
      .map(([id, row]) => memoryHit(id, row.body, row.status));
    return { traceID: "recall", projectID: "project-p18", hits };
  };
  const tree = () => ({
    nodes: [...state.values()]
      .flatMap((row) => {
        if (row.status === "quarantined")
          return [
            { name: row.body },
            { name: "Save as memory" },
            { name: "Reject" },
          ];
        if (row.status === "approved")
          return [
            { name: row.body },
            { name: "Approved" },
            { name: "Forget permanently" },
          ];
        if (row.status === "rejected")
          return [{ name: row.body }, { name: "Rejected" }];
        return [
          { name: "Forgotten" },
          { name: "(Memory contents unavailable)" },
        ];
      })
      .concat([{ name: "Audit trail" }]),
  });
  const ui = {
    async launch() {
      launches += 1;
      return { pid: 900 + launches };
    },
    snapshot() {
      return tree();
    },
    screenshot(name) {
      return write(
        path.join(options.rawOutputDir, name),
        Buffer.alloc(2048, launches),
      );
    },
    async stop() {},
  };
  const daemon = { async prepare() {}, async restart() {}, async restore() {} };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    daemon,
    rpc,
    ui,
    marker: "P18-fedcba0987654321",
  };
}

test("P-18 native runner records quarantine, decisions, audit, and restart UI", async () => {
  const value = fixture();
  try {
    const result = await runP18NativeMemoryProbes(
      value.options,
      dependencies(value.options),
    );
    assert.match(result.memoryID, /^mem_[a-f0-9]{32}$/u);
    const daemon = JSON.parse(
      fs.readFileSync(
        path.join(result.output, "memory-daemon-transcript.json"),
      ),
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "memory-ui-transcript.json")),
    );
    assert.deepEqual(
      daemon.events.map((event) => event.phase),
      [
        "quarantine-created",
        "normal-recall-excludes-quarantine",
        "review-feed-includes-quarantine",
        "approved",
        "normal-recall-includes-approved",
        "rejected-candidate-created",
        "rejected",
        "normal-recall-excludes-rejected",
        "forgotten",
        "forgotten-tombstone",
        "restart-readback",
        "audit-readback",
      ],
    );
    assert.deepEqual(
      ui.events.map((event) => event.phase),
      ["pending", "approved", "rejected-forgotten", "restart"],
    );
    assert.equal(ui.events[2].observed.forgottenBodyAbsent, true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-18 native runner retains failed RPC evidence and aborts on daemon failure", async () => {
  const value = fixture();
  try {
    const deps = dependencies(value.options);
    const original = deps.rpc;
    let calls = 0;
    deps.rpc = async (...args) => {
      calls += 1;
      if (calls === 2) throw new Error("forced recall failure");
      return original(...args);
    };
    await assert.rejects(
      runP18NativeMemoryProbes(value.options, deps),
      /forced recall failure/u,
    );
    assert.equal(
      fs.existsSync(
        path.join(value.options.rawOutputDir, "memory-daemon-transcript.json"),
      ),
      false,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
