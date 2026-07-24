import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { runP23NativeProviderWorkspaceProbes } from "./run-p23-native-provider-workspace-probes.mjs";

function fixture() {
  const base = path.join(process.cwd(), ".tmp/p23-proof-tests");
  fs.mkdirSync(base, { recursive: true });
  const root = fs.mkdtempSync(path.join(base, "native-"));
  const tokenFile = path.join(root, "daemon-token");
  fs.writeFileSync(tokenFile, "a".repeat(64), { mode: 0o600 });
  return {
    root,
    options: {
      rawOutputDir: path.join(root, "raw"),
      socketPath: path.join(root, "daemon.sock"),
      tokenFile,
      manifestSha256: "b".repeat(64),
    },
  };
}
function tree(names, focusedName = null) {
  return {
    nodes: names.map((name) => ({
      name,
      states: name === focusedName ? ["focused"] : [],
    })),
  };
}
function dependencies(options, { singleSlot = false } = {}) {
  const foundationSeconds = (Date.now() - Date.UTC(2001, 0, 1)) / 1000;
  const original = {
    routerMode: "provider_family_failover",
    telemetryEnabled: false,
    privacyOptIn: false,
    cloudSyncEnabled: false,
    secretRef: "p23-test-secret-reference",
    providers: [
      {
        providerID: "codex",
        isEnabled: true,
        preferredCredentialSlotID: "slot-a",
        credentialSlots: [
          {
            slotID: "slot-a",
            label: "Primary",
            isEnabled: true,
            status: "ready",
            updatedAt: foundationSeconds,
          },
          ...(singleSlot
            ? []
            : [
                {
                  slotID: "slot-b",
                  label: "Backup",
                  isEnabled: true,
                  status: "ready",
                  updatedAt: foundationSeconds,
                },
              ]),
        ],
        modelVariants: [],
        modelAliases: [],
        modelDisplayOverrides: [],
        customModels: [],
        preferredModelIDs: ["gpt-5"],
        disabledAdvertisedModelIDs: [],
        ollamaEndpoints: [],
        baseURL: "https://api.example.test",
      },
    ],
  };
  let config = structuredClone(original);
  let routes = [];
  let run = 0;
  let launches = 0;
  let restarts = 0;
  const requests = [];
  const launchedUris = [];
  const forwardedUris = [];
  const rpc = async (method, params) => {
    requests.push({ method, params: structuredClone(params ?? {}) });
    if (method === "daemon.config.get")
      return { snapshot: structuredClone(config) };
    if (method === "daemon.catalog")
      return {
        catalog: {
          providers: [
            {
              id: "codex",
              displayName: "Codex",
              models: [{ id: "gpt-5", displayName: "GPT-5" }],
              capabilities: ["chat"],
            },
          ],
        },
      };
    if (method === "daemon.quota.signals.recent")
      return { signals: [], snapshots: [] };
    if (method === "daemon.proxy.route_log.recent") return { entries: routes };
    if (method === "daemon.config.update") {
      config = structuredClone(params.snapshot);
      return { snapshot: structuredClone(config) };
    }
    if (method === "daemon.provider.custom_model.upsert") {
      const provider = config.providers[0];
      provider.customModels = [
        ...provider.customModels.filter(
          (row) => row.modelID !== params.customModel.modelID,
        ),
        params.customModel,
      ];
      return {
        snapshot: structuredClone(config),
        customModel: params.customModel,
      };
    }
    if (method === "daemon.provider.model_alias.upsert") {
      const provider = config.providers[0];
      provider.modelAliases = [
        ...provider.modelAliases.filter(
          (row) => row.aliasID !== params.alias.aliasID,
        ),
        params.alias,
      ];
      return { snapshot: structuredClone(config), alias: params.alias };
    }
    if (method === "daemon.provider.model_variant.upsert") {
      const provider = config.providers[0];
      provider.modelVariants = [
        ...provider.modelVariants.filter(
          (row) => row.variantID !== params.variant.variantID,
        ),
        params.variant,
      ];
      return { snapshot: structuredClone(config), variant: params.variant };
    }
    if (
      ["client.attach", "client.claimControl", "client.detach"].includes(method)
    )
      return { ok: true };
    if (method === "run.create") {
      run += 1;
      const provider = config.providers[0];
      const chosen = run === 1 ? "slot-a" : "slot-b";
      routes = [
        {
          id: `route-${run}`,
          occurredAt: (Date.now() + run - Date.UTC(2001, 0, 1)) / 1000,
          finalStatus: "exact",
          httpStatus: 200,
          providerID: "codex",
          accountID: chosen,
          clientModelSlug: params.modelID,
        },
        ...routes,
      ];
      return { runID: `run-${run}`, phase: "completed" };
    }
    if (method === "run.get")
      return { run: { runID: params.runID, phase: "completed" } };
    throw new Error(`unexpected RPC ${method}`);
  };
  const service = {
    async preflight() {},
    async restart() {
      restarts += 1;
    },
  };
  const marker = "p23-fedcba0987654321";
  const custom = "gpt-5-p23-87654321";
  const alias = "p23-alias-87654321";
  const variant = "p23-variant-87654321";
  const ui = {
    async launch(uri) {
      launches += 1;
      launchedUris.push(uri);
      return { pid: 2300 + launches };
    },
    async forward(uri) {
      forwardedUris.push(uri);
    },
    async activate() {},
    async stop() {},
    snapshot(label) {
      if (label === "detail")
        return tree([
          "Providers & models",
          "codex",
          "Healthy",
          "Eligible",
          "Primary · exhausted",
        ]);
      if (label === "model-forward")
        return tree(["codex", custom, alias, variant], custom);
      if (label === "alias-forward") return tree(["codex", alias], alias);
      if (label === "degraded")
        return tree(["Degraded", "Unavailable", "Primary · coolingDown"]);
      if (label === "unavailable")
        return tree([
          "Unavailable",
          "Primary · missingSecret",
          "No verified credential route is available",
        ]);
      throw new Error(`unexpected snapshot ${label}`);
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      fs.writeFileSync(file, Buffer.alloc(2048, launches + name.length));
      return file;
    },
  };
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier: () => ({}),
    desktopProcessIDs: () => [],
    marker,
    rpc,
    service,
    ui,
    restored: () => JSON.stringify(config) === JSON.stringify(original),
    restarts: () => restarts,
    requests: () => requests,
    launchedUris: () => launchedUris,
    forwardedUris: () => forwardedUris,
  };
}

test("P-23 native runner proves two live accounts, deterministic drain, lifecycle, deep links, and health states", async () => {
  const value = fixture();
  const deps = dependencies(value.options);
  try {
    const result = await runP23NativeProviderWorkspaceProbes(
      value.options,
      deps,
    );
    const daemon = JSON.parse(
      fs.readFileSync(
        path.join(result.output, "provider-daemon-transcript.json"),
      ),
    );
    const ui = JSON.parse(
      fs.readFileSync(path.join(result.output, "provider-ui-transcript.json")),
    );
    assert.doesNotMatch(JSON.stringify(daemon), /p23-test-secret-reference/u);
    assert.doesNotMatch(JSON.stringify(daemon), /secretRef/u);
    assert.ok(
      daemon.events.some(
        (event) =>
          event.phase === "manual-a-route" &&
          event.result.accountID === "slot-a",
      ),
    );
    assert.ok(
      daemon.events.some(
        (event) =>
          event.phase === "manual-b-route" &&
          event.result.accountID === "slot-b",
      ),
    );
    assert.ok(
      daemon.events.some(
        (event) =>
          event.phase === "automatic-drain-route" &&
          event.result.accountID === "slot-b",
      ),
    );
    assert.deepEqual(
      ui.events.map((event) => event.phase),
      [
        "detail",
        "model-deep-link",
        "deep-link-restoration",
        "degraded",
        "unavailable",
      ],
    );
    assert.equal(deps.restored(), true);
    assert.ok(deps.restarts() >= 2);
    assert.deepEqual(deps.launchedUris(), [
      "openburnbar://providers?provider=codex",
    ]);
    assert.deepEqual(deps.forwardedUris(), [
      "openburnbar://providers?provider=codex&model=gpt-5-p23-87654321",
      "openburnbar://providers?provider=codex&model=p23-alias-87654321",
    ]);
    const mutations = deps
      .requests()
      .filter(({ method }) =>
        [
          "daemon.config.update",
          "daemon.provider.custom_model.upsert",
          "daemon.provider.model_alias.upsert",
          "daemon.provider.model_variant.upsert",
        ].includes(method),
      );
    const serialized = JSON.stringify(mutations);
    assert.doesNotMatch(serialized, /2026-\d{2}-\d{2}T/u);
    const firstConfig = mutations.find(
      ({ method }) => method === "daemon.config.update",
    );
    assert.equal(
      typeof firstConfig.params.snapshot.providers[0].credentialSlots[0]
        .updatedAt,
      "number",
    );
    const customMutation = mutations.find(
      ({ method }) => method === "daemon.provider.custom_model.upsert",
    );
    assert.equal(typeof customMutation.params.customModel.createdAt, "number");
    for (const name of [
      "provider-marker.json",
      "provider-daemon-transcript.json",
      "provider-ui-transcript.json",
      "provider-detail.png",
      "provider-model-deep-link.png",
      "provider-deep-link-restored.png",
      "provider-degraded.png",
      "provider-unavailable.png",
    ])
      assert.ok(fs.statSync(path.join(result.output, name)).size > 0, name);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});

test("P-23 native runner fails instead of claiming live failover without two credential slots", async () => {
  const value = fixture();
  const deps = dependencies(value.options, { singleSlot: true });
  try {
    await assert.rejects(
      runP23NativeProviderWorkspaceProbes(value.options, deps),
      /two enabled native credential slots/u,
    );
    assert.equal(deps.restored(), true);
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
