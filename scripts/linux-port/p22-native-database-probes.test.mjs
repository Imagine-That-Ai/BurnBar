import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP22NativeDatabaseProbes } from "./run-p22-native-database-probes.mjs";

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p22-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "native-"));
  const rawOutputDir = path.join(root, "raw");
  const supportDir = path.join(root, "support");
  const homeDir = path.join(root, "home");
  fs.mkdirSync(supportDir, { mode: 0o700 });
  const tokenFile = path.join(supportDir, "daemon-token");
  fs.writeFileSync(tokenFile, "a".repeat(64), { mode: 0o600 });
  return {
    root,
    options: {
      rawOutputDir,
      supportDir,
      homeDir,
      tokenFile,
      socketPath: path.join(supportDir, "daemon.sock"),
      indexDatabase: path.join(supportDir, "index.sqlite"),
      manifestSha256: "b".repeat(64),
    },
  };
}
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function tree(names) {
  return { nodes: names.map((name) => ({ name, states: [] })) };
}
function dependencies(options, { recoveryPhase = "ready" } = {}) {
  let projectPath;
  let query;
  let watcherQuery;
  let launches = 0;
  let restored = false;
  const daemon = {
    async prepare() {},
    async restart() {},
    async restore() {
      restored = true;
    },
  };
  const hits = (needle, count = 14) =>
    Array.from({ length: count }, (_, index) => ({
      filePath: `record-${String(index).padStart(2, "0")}.ts`,
      snippet: `export const value = "${needle}";`,
      line: 1,
    }));
  const trust = (sourceTool) => ({
    sourceTool,
    untrustedContentWrapped: true,
  });
  const rpc = async (method, params) => {
    if (method === "daemon.code.index_project") {
      projectPath = params.projectPath;
      return { projectRoot: projectPath, indexedFiles: 14, chunkCount: 14 };
    }
    if (method === "daemon.code.watch_project")
      return { projectRoot: projectPath, watching: true };
    if (method === "daemon.code.search") {
      if (!query) query = params.query;
      else if (params.query !== query) watcherQuery = params.query;
      return {
        hits: hits(params.query, params.query === query ? 14 : 1),
        trustSignal: trust("daemon.code.search"),
      };
    }
    if (method === "daemon.code.context_pack")
      return {
        hits: hits(params.query, 10),
        context: `Untrusted source data\n${params.query}`,
        trustSignal: trust("daemon.code.context_pack"),
      };
    if (method === "daemon.code.explore")
      return { files: hits(query).map(({ filePath }) => ({ filePath })) };
    if (method === "daemon.code.index_status")
      return { artifactCount: 14, databaseEncrypted: true };
    if (method === "daemon.database.recovery.status")
      return {
        phase: recoveryPhase,
        code: recoveryPhase,
        canExport: recoveryPhase === "ready",
        databaseIntegrityVerified: recoveryPhase === "ready",
      };
    if (method === "daemon.code.database_snapshot") {
      const bytes = Buffer.from("encrypted-sqlcipher-snapshot");
      fs.writeFileSync(params.destinationPath, bytes, { mode: 0o600 });
      return {
        byteCount: bytes.length,
        sha256: hash(bytes),
        databaseEncrypted: true,
        integrityCheck: "ok",
      };
    }
    if (method === "daemon.code.database_restore") {
      const bytes = fs.readFileSync(params.snapshotPath);
      return {
        byteCount: bytes.length,
        sha256: hash(bytes),
        databaseEncrypted: true,
        integrityCheck: "ok",
      };
    }
    if (method === "daemon.database.recovery_bundle.export") {
      const bytes = Buffer.from("encrypted-recovery-bundle");
      fs.writeFileSync(params.destinationPath, bytes, { mode: 0o600 });
      return { byteCount: bytes.length, formatVersion: 1 };
    }
    if (method === "daemon.database.recovery_bundle.import") {
      if (
        params.passphrase !== "fixture-passphrase" ||
        params.sourcePath.endsWith(".tampered.obb")
      )
        throw new Error("recovery bundle authentication failed");
      return {
        stored: true,
        candidateKeyVerified: true,
        databaseIntegrityVerified: true,
        phase: "ready",
        restartRequired: true,
      };
    }
    throw new Error(`unexpected RPC ${method}`);
  };
  const ui = {
    async launch() {
      launches += 1;
      return { pid: 2200 + launches };
    },
    async activate() {},
    async setText(_name, value) {
      query = value;
    },
    async stop() {},
    snapshot(label) {
      if (label === "atlas")
        return tree(["Indexed corpus", "record-00.ts", "Inspect record-00.ts"]);
      if (label === "inspector")
        return tree([
          "Record inspector",
          "record-00.ts",
          "Source contents are not fetched or inferred by this view.",
        ]);
      if (label === "search")
        return tree(["14 matching snippets", "Page 1 of 2"]);
      if (label === "page-two") return tree(["Page 2 of 2"]);
      if (label === "context-pack")
        return tree(["Code context pack", "Untrusted source data."]);
      if (label === "system")
        return tree([
          "Sealed",
          "Encrypted snapshot & recovery",
          "Recovery state: Ready",
          "Indexing control",
        ]);
      if (label === "restart") return tree(["Indexed corpus", "record-00.ts"]);
      throw new Error(`unexpected UI snapshot ${label}`);
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      fs.writeFileSync(file, Buffer.alloc(2048, launches));
      return file;
    },
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    marker: "p22-fedcba0987654321",
    passphrase: "fixture-passphrase",
    daemon,
    rpc,
    ui,
    restored: () => restored,
    watcher: () => watcherQuery,
  };
}

test("P-22 native runner proves populated Database and real recovery contracts", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  try {
    const result = await runP22NativeDatabaseProbes(value.options, deps);
    const daemon = JSON.parse(
      fs.readFileSync(
        path.join(result.output, "database-daemon-transcript.json"),
      ),
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "database-ui-transcript.json")),
    );
    assert.equal(daemon.events.length, 16);
    assert.deepEqual(
      daemon.events.filter((event) => !event.ok).map((event) => event.phase),
      ["wrong-passphrase", "tampered-bundle"],
    );
    assert.deepEqual(
      ui.events.map((event) => event.phase),
      ["atlas", "inspector", "retrieval", "system", "restart"],
    );
    assert.equal(deps.restored(), true);
    assert.match(deps.watcher(), /^P22WatcherMarker_/u);
    const text = fs.readFileSync(
      path.join(result.output, "database-daemon-transcript.json"),
      "utf8",
    );
    assert.doesNotMatch(text, /fixture-passphrase/u);
    for (const name of [
      "database-marker.json",
      "database-daemon-transcript.json",
      "database-ui-transcript.json",
      "database-atlas.png",
      "database-inspector.png",
      "database-retrieval.png",
      "database-system.png",
      "database-restart.png",
    ])
      assert.ok(fs.statSync(path.join(result.output, name)).size > 0, name);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-22 native runner fails closed when native recovery is unavailable", async () => {
  const value = fixture();
  const deps = dependencies(value.options, {
    recoveryPhase: "key_unavailable",
  });
  try {
    await assert.rejects(
      runP22NativeDatabaseProbes(value.options, deps),
      /requires real SQLCipher\/native-key readiness.*key_unavailable/u,
    );
    assert.equal(deps.restored(), true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
