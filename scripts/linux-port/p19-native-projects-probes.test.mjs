import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP19NativeProjectsProbes } from "./run-p19-native-projects-probes.mjs";

const IDENTITY = {
  environmentId: "ubuntu-24.04-gnome-x11-aarch64",
  targetHead: "a".repeat(40),
  candidateRunId: "191919",
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
  const base = path.join(process.cwd(), ".tmp/p19-native-probe-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "case-"));
  fs.chmodSync(root, 0o700);
  const rawOutputDir = path.join(root, "raw");
  const supportDir = path.join(root, "support");
  const homeDir = path.join(root, "home");
  fs.mkdirSync(rawOutputDir, { mode: 0o700 });
  fs.mkdirSync(supportDir, { mode: 0o700 });
  fs.mkdirSync(homeDir, { mode: 0o700 });
  const tokenFile = write(path.join(supportDir, "token"), `${"e".repeat(64)}\n`);
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

function dependencies(options, { failMethod = null } = {}) {
  const projects = new Map();
  const deleted = new Map();
  const missions = new Map();
  let launches = 0;
  let restarts = 0;
  const resolve = (identifier, includeDeleted = false) => {
    for (const project of projects.values())
      if (
        project.projectSlug === identifier ||
        project.id === identifier ||
        project.aliases.includes(identifier)
      )
        return project.projectSlug;
    if (includeDeleted) return deleted.get(identifier) ?? null;
    return null;
  };
  const rpc = async (method, request) => {
    if (method === failMethod) throw new Error(`forced ${method} failure`);
    if (method === "daemon.controller.project.upsert") {
      const project = request.project;
      const identities = [project.projectSlug, project.id, ...project.aliases];
      if (identities.some((identity) => deleted.has(identity)))
        throw new Error(`project deleted: ${project.projectSlug}`);
      projects.set(project.projectSlug, structuredClone(project));
      return { project: structuredClone(project) };
    }
    if (method === "daemon.controller.project.list")
      return {
        projects: [...projects.values()].map((project) =>
          structuredClone(project),
        ),
      };
    if (method === "daemon.controller.project.get") {
      const slug = resolve(request.projectSlug);
      return { project: slug ? structuredClone(projects.get(slug)) : null };
    }
    if (method === "daemon.mission.create") {
      const mission = {
        id: `mission-${request.metadata.p19_marker}`,
        projectSlug: request.projectSlug,
      };
      missions.set(mission.id, mission);
      return { mission: structuredClone(mission) };
    }
    if (method === "daemon.mission.get")
      return { mission: structuredClone(missions.get(request.missionID) ?? null) };
    if (method === "daemon.controller.project.delete") {
      const slug = resolve(request.projectSlug);
      const project = projects.get(slug);
      for (const identity of [project.projectSlug, project.id, ...project.aliases])
        deleted.set(identity, slug);
      projects.delete(slug);
      return { projectSlug: slug, deleted: true };
    }
    if (method === "daemon.controller.project.reassign") {
      const source = resolve(request.sourceProjectSlug, true);
      const target = resolve(request.targetProjectSlug);
      if (!source || !target) throw new Error("project not found");
      let updatedReferenceCount = 0;
      for (const mission of missions.values()) {
        if (mission.projectSlug !== source) continue;
        mission.projectSlug = target;
        updatedReferenceCount += 1;
      }
      return {
        sourceProjectSlug: source,
        targetProjectSlug: target,
        updatedReferenceCount,
      };
    }
    throw new Error(`unexpected RPC ${method}`);
  };
  const tree = () => ({
    nodes: [
      ...[...projects.values()].map((project) => ({ name: project.displayName })),
      { name: "Open details" },
      { name: "Register project" },
      { name: "Project history" },
    ],
  });
  const ui = {
    async launch() {
      launches += 1;
      return { pid: 1900 + launches };
    },
    snapshot() {
      return tree();
    },
    screenshot(name) {
      return write(path.join(options.rawOutputDir, name), Buffer.alloc(2048, launches));
    },
    async openProject(displayName) {
      assert.match(displayName, /P19 Target/u);
    },
    async stop() {},
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    daemon: {
      async prepare() {},
      async restart() {
        restarts += 1;
      },
      async restore() {},
    },
    rpc,
    ui,
    marker: "p19-fedcba0987654321",
  };
}

test("P-19 native runner records CRUD, tombstone, reassignment, restart, and UI", async () => {
  const value = fixture();
  try {
    const result = await runP19NativeProjectsProbes(
      value.options,
      dependencies(value.options),
    );
    assert.equal(result.sourceSlug, "p19-fedcba0987654321-source");
    assert.equal(result.targetSlug, "p19-fedcba0987654321-target");
    const daemon = JSON.parse(
      fs.readFileSync(path.join(result.output, "projects-daemon-transcript.json")),
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "projects-ui-transcript.json")),
    );
    assert.deepEqual(
      daemon.events.map((event) => event.phase),
      [
        "source-upserted",
        "target-upserted",
        "initial-list",
        "source-get-by-alias",
        "associated-mission-created",
        "source-deleted",
        "deleted-source-reassigned",
        "reassigned-mission-get",
        "post-delete-list",
        "post-delete-get",
        "restart-list",
        "restart-get-deleted",
        "restart-mission-get",
        "restart-upsert-rejected-by-tombstone",
        "restart-reassign-from-tombstone",
      ],
    );
    const rejection = daemon.events.find(
      (event) => event.phase === "restart-upsert-rejected-by-tombstone",
    );
    assert.equal(rejection.ok, false);
    assert.match(rejection.error, /project deleted/u);
    assert.deepEqual(ui.events.map((event) => event.phase), [
      "initial",
      "restart-list",
      "restart-detail",
    ]);
    assert.equal(ui.events[1].observed.sourceAbsent, true);
    for (const name of [
      "projects-marker.json",
      "projects-daemon-transcript.json",
      "projects-ui-transcript.json",
      "projects-initial.png",
      "projects-restart.png",
    ])
      assert.ok(fs.statSync(path.join(result.output, name)).size > 0, name);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-19 native runner retains failed RPC evidence and restores daemon", async () => {
  const value = fixture();
  let restored = false;
  const deps = dependencies(value.options, {
    failMethod: "daemon.controller.project.delete",
  });
  deps.daemon.restore = async () => {
    restored = true;
  };
  try {
    await assert.rejects(
      runP19NativeProjectsProbes(value.options, deps),
      /forced daemon\.controller\.project\.delete/u,
    );
    assert.equal(restored, true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
