import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { runP21NativeInsightsProbes } from "./run-p21-native-insights-probes.mjs";

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "p21-native-"));
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

function tree(names, selected = []) {
  return {
    nodes: names.map((name) => ({
      name,
      states: selected.includes(name) ? ["checked"] : [],
    })),
  };
}

function dependencies(options, { failInsights = false } = {}) {
  const usage = [];
  let insights = 0;
  let launches = 0;
  let restored = false;
  const daemon = {
    async prepare() {},
    async restart() {},
    async stopForSourceLoss() {},
    async restore() {
      restored = true;
    },
  };
  const rpc = async (method, params) => {
    if (method === "daemon.usage.record") {
      usage.push(params.event);
      return {
        idempotencyKey: params.idempotencyKey,
        inserted: true,
        event: params.event,
      };
    }
    if (failInsights) throw new Error("forced insights failure");
    insights += 1;
    const citation = { id: `citation-${insights}`, label: "codex session" };
    return {
      usage,
      sourceID: "daemon.usage.ledger",
      sourceLabel: "Linux daemon usage ledger · local rules",
      analysis: {
        requestID: `request-${insights}`,
        generatedAt: new Date(Date.now() - 100 + insights).toISOString(),
        executiveSummary: "Three providers recorded bounded local usage.",
        modelTag: { displayName: "Linux local rules" },
        citations: [citation],
        findings: [
          {
            id: "provider-mix",
            title: "Provider mix changed",
            whyItMatters: "Routing is distributed.",
            recommendedAction: "Review provider scopes.",
            evidence: [citation],
          },
        ],
      },
    };
  };
  const ui = {
    async launch() {
      launches += 1;
      return { pid: 2100 + launches };
    },
    snapshot(label) {
      if (label === "initial")
        return tree([
          "Usage observatory",
          "Provenance: daemon-authored qualitative insights",
          "Daemon qualitative brief",
          "Fresh",
          "Open citation: codex session",
          "Insight inspector",
        ]);
      if (label === "configured")
        return tree(
          [
            "Compact",
            "Model mix",
            "3 of 3 selected",
            "Side-by-side comparison",
            "Provenance: one",
            "Provenance: two",
            "Provenance: three",
          ],
          ["Compact", "Model mix"],
        );
      if (label === "audit") return tree(["Insights audit"]);
      if (label === "chat-handoff")
        return tree(["Chat", "Explain the Insights evidence", "codex session"]);
      if (label === "restart")
        return tree(["Compact", "Model mix"], ["Compact", "Model mix"]);
      if (label === "source-loss")
        return tree([
          "Usage observatory",
          "Model mix",
          "Showing the last successful Insights snapshot",
        ]);
      throw new Error(`unexpected snapshot ${label}`);
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      fs.writeFileSync(file, Buffer.alloc(2048, launches));
      return file;
    },
    async activate() {},
    async stop() {},
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    marker: "p21-fedcba0987654321",
    daemon,
    rpc,
    ui,
    restored: () => restored,
  };
}

test("P-21 native runner records populated qualitative, compare, persistence, and source loss", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  try {
    const result = await runP21NativeInsightsProbes(value.options, deps);
    assert.equal(result.marker, "p21-fedcba0987654321");
    const daemon = JSON.parse(
      fs.readFileSync(
        path.join(result.output, "insights-daemon-transcript.json"),
      ),
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "insights-ui-transcript.json")),
    );
    assert.deepEqual(
      daemon.events.map((event) => event.phase),
      [
        "record-codex",
        "record-claude",
        "record-gemini",
        "insights-initial",
        "insights-refresh",
        "insights-restart",
      ],
    );
    assert.deepEqual(
      ui.events.map((event) => event.phase),
      ["initial", "configured", "chat-handoff", "restart", "source-loss"],
    );
    assert.equal(ui.events[1].observed.compareCount, 3);
    assert.equal(ui.events[4].observed.snapshotPreserved, true);
    assert.equal(deps.restored(), true);
    for (const name of [
      "insights-marker.json",
      "insights-daemon-transcript.json",
      "insights-ui-transcript.json",
      "insights-initial.png",
      "insights-compare.png",
      "insights-restart.png",
      "insights-source-loss.png",
    ])
      assert.ok(fs.statSync(path.join(result.output, name)).size > 0, name);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-21 native runner preserves failed RPC evidence path and restores daemon", async () => {
  const value = fixture();
  const deps = dependencies(value.options, { failInsights: true });
  try {
    await assert.rejects(
      runP21NativeInsightsProbes(value.options, deps),
      /forced insights failure/u,
    );
    assert.equal(deps.restored(), true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
