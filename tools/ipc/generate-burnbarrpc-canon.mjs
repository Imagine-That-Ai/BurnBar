#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const root = path.resolve(path.dirname(scriptPath), "../..");

const files = {
  contracts: path.join(root, "OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift"),
  capability: path.join(root, "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift"),
  coverage: path.join(root, "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC/BurnBarDaemonSocketRPCCoverage.swift"),
  swift: path.join(root, "OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCIPCCanon.generated.swift"),
  typescript: path.join(root, "extensions/openburnbar/src/generated/burnbar-rpc-ipc-canon.generated.ts"),
  json: path.join(root, "docs/linux-port/generated/burnbar-rpc-ipc-canon.linux.json")
};

const args = process.argv.slice(2);
const check = args.includes("--check");
const fixtureIndex = args.indexOf("--fixture");
const fixturePath = fixtureIndex >= 0 ? args[fixtureIndex + 1] : null;
if (fixtureIndex >= 0 && !fixturePath) {
  console.error("--fixture requires a path");
  process.exit(2);
}

function read(file) {
  return readFileSync(file, "utf8");
}

function parseMethods(source) {
  const start = source.indexOf("public enum BurnBarRPCMethod");
  const end = source.indexOf("public struct BurnBarRPCRequestEnvelope", start);
  if (start < 0 || end < 0) {
    throw new Error("Could not isolate BurnBarRPCMethod enum body");
  }
  const methodSource = source.slice(start, end);
  const methods = [];
  const methodRe = /^\s*case\s+([A-Za-z0-9_]+)\s*=\s*"([^"]+)"/gm;
  let match;
  while ((match = methodRe.exec(methodSource))) {
    methods.push({ caseName: match[1], id: match[2] });
  }
  if (methods.length === 0) {
    throw new Error("No BurnBarRPCMethod cases parsed");
  }
  return methods;
}

function parseCapabilities(source) {
  const start = source.indexOf("public static func capability(for method: BurnBarRPCMethod)");
  if (start < 0) throw new Error("Could not find capability(for:) switch");
  const switchStart = source.indexOf("switch method", start);
  const end = source.indexOf("/// The attenuated capability set", switchStart);
  const body = source.slice(switchStart, end);
  const lines = body.split(/\r?\n/);
  const map = new Map();
  let caseBuffer = "";
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed.startsWith("case ")) {
      caseBuffer = trimmed;
      continue;
    }
    if (caseBuffer && trimmed.startsWith(".")) {
      caseBuffer += " " + trimmed;
      continue;
    }
    const returnMatch = trimmed.match(/^return \.([A-Za-z0-9_]+)/);
    if (caseBuffer && returnMatch) {
      const capability = swiftCaseToWire(returnMatch[1]);
      const caseText = caseBuffer.split(":")[0];
      for (const method of caseText.matchAll(/\.([A-Za-z0-9_]+)/g)) {
        map.set(method[1], capability);
      }
      caseBuffer = "";
    }
  }
  return map;
}

function parseDomains(source) {
  const map = new Map();
  const setRe = /static let ([A-Za-z0-9_]+): Set<BurnBarRPCMethod> = \[([\s\S]*?)\]/g;
  let match;
  while ((match = setRe.exec(source))) {
    const domain = domainName(match[1]);
    for (const method of match[2].matchAll(/\.([A-Za-z0-9_]+)/g)) {
      map.set(method[1], domain);
    }
  }
  return map;
}

function swiftCaseToWire(name) {
  return name.replace(/[A-Z]/g, (char) => "_" + char.toLowerCase());
}

function domainName(name) {
  const explicit = {
    computerUse: "computer_use",
    missionControl: "mission_control",
    runWorkspaceApproval: "run_workspace_approval"
  };
  return explicit[name] ?? swiftCaseToWire(name);
}

const explicitTypes = {
  "daemon.account.cloud_data.delete": ["BurnBarLinuxAccountCloudDataDeletionRequest", "BurnBarLinuxAccountCloudDataDeletionResponse"],
  "daemon.account.trusted_devices.list": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxTrustedDeviceListResponse"],
  "daemon.account.trusted_device.approve": ["BurnBarLinuxTrustedDeviceMutationRequest", "BurnBarLinuxTrustedDeviceMutationResponse"],
  "daemon.account.trusted_device.revoke": ["BurnBarLinuxTrustedDeviceMutationRequest", "BurnBarLinuxTrustedDeviceMutationResponse"],
  "daemon.auth.status": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxAuthStatusResponse"],
  "daemon.auth.begin": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxAuthBeginResponse"],
  "daemon.auth.cancel": ["BurnBarLinuxAuthCancelRequest", "BurnBarLinuxAuthMutationResponse"],
  "daemon.auth.rotate_identity": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxAuthMutationResponse"],
  "daemon.auth.sign_out": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxAuthMutationResponse"],
  "daemon.cloud_sync.status": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxCloudSyncStatusResponse"],
  "daemon.cloud_sync.policy.update": ["BurnBarLinuxCloudSyncPolicyUpdateRequest", "BurnBarLinuxCloudSyncStatusResponse"],
  "daemon.cloud_sync.run": ["BurnBarLinuxCloudSyncRunRequest", "BurnBarLinuxCloudSyncRunResponse"],
  "daemon.health": ["BurnBarRPCRequestEnvelope", "BurnBarHealthResponse"],
  "daemon.catalog": ["BurnBarRPCRequestEnvelope", "BurnBarCatalogResponse"],
  "daemon.config.get": ["BurnBarConfigGetRequest", "BurnBarConfigResponse"],
  "daemon.memory.model_policy": ["BurnBarMemoryModelPolicyRequest", "BurnBarMemoryModelPolicyResponse"],
  "daemon.config.update": ["BurnBarConfigUpdateRequest", "BurnBarConfigResponse"],
  "daemon.text_expansion.get": ["BurnBarRPCRequestEnvelope", "BurnBarTextExpansionSnapshot"],
  "daemon.text_expansion.upsert": ["BurnBarTextExpansionUpsertRequest", "BurnBarTextExpansionWireSnippet"],
  "daemon.text_expansion.delete": ["BurnBarTextExpansionDeleteRequest", "BurnBarTextExpansionSnapshot"],
  "daemon.text_expansion.consent.update": ["BurnBarTextExpansionConsentUpdateRequest", "BurnBarTextExpansionConsentResponse"],
  "daemon.text_expansion.engine.expand": ["BurnBarTextExpansionEngineExpandRequest", "BurnBarTextExpansionEngineExpandResponse"],
  "daemon.privacy.inventory": ["BurnBarRPCRequestEnvelope", "BurnBarLinuxPrivacyInventoryResponse"],
  "daemon.privacy.deletion.preview": ["BurnBarLinuxPrivacyDeletionPreviewRequest", "BurnBarLinuxPrivacyDeletionPreviewResponse"],
  "daemon.privacy.deletion.execute": ["BurnBarLinuxPrivacyDeletionExecuteRequest", "BurnBarLinuxPrivacyDeletionExecuteResponse"],
  "daemon.privacy.export": ["BurnBarLinuxPrivacyExportRequest", "BurnBarLinuxPrivacyExportResponse"],
  "daemon.privacy.retention.status": ["BurnBarLinuxPrivacyRetentionStatusRequest", "BurnBarLinuxPrivacyRetentionStatusResponse"],
  "daemon.privacy.retention.apply": ["BurnBarLinuxPrivacyRetentionApplyRequest", "BurnBarLinuxPrivacyRetentionApplyResponse"],
  "daemon.media.session.state": ["BurnBarRPCRequestEnvelope", "DaemonMediaSessionStateResponse"],
  "daemon.media.call.accept": ["DaemonMediaCallAcceptRequest", "DaemonMediaCallActionResponse"],
  "daemon.media.call.decline": ["DaemonMediaCallDeclineRequest", "DaemonMediaCallActionResponse"],
  "daemon.media.call.end": ["DaemonMediaCallEndRequest", "DaemonMediaCallActionResponse"],
  "daemon.media.capability.get": ["BurnBarRPCRequestEnvelope", "DaemonMediaCapabilityResponse"],
  "daemon.media.status": ["BurnBarRPCRequestEnvelope", "DaemonMediaStatusResponse"],
  "daemon.media.file.offer.list": ["BurnBarRPCRequestEnvelope", "DaemonMediaFileOfferListResponse"],
  "daemon.media.file.accept": ["DaemonMediaFileAcceptRequest", "DaemonMediaFileActionResponse"],
  "daemon.media.file.decline": ["DaemonMediaFileDeclineRequest", "DaemonMediaFileActionResponse"],
  "daemon.media.file.send": ["DaemonMediaFileSendRequest", "DaemonMediaFileActionResponse"],
  "daemon.provider.credential_slot.upsert": ["BurnBarProviderCredentialSlotUpsertRequest", "BurnBarProviderCredentialSlotMutationResponse"],
  "daemon.provider.credential_slot.remove": ["BurnBarProviderCredentialSlotRemoveRequest", "BurnBarProviderCredentialSlotMutationResponse"],
  "daemon.chat.thread.list": ["BurnBarChatThreadListRequest", "BurnBarChatThreadListResponse"],
  "daemon.chat.thread.get": ["BurnBarChatThreadGetRequest", "BurnBarChatThreadGetResponse"],
  "daemon.chat.message.append": ["BurnBarChatMessageAppendRequest", "BurnBarChatMessageAppendResponse"],
  "daemon.usage.history": ["BurnBarActivityHistoryRequest", "BurnBarActivityHistoryResponse"],
  "daemon.usage.insights": ["BurnBarUsageInsightsRequest", "BurnBarUsageInsightsResponse"],
  "daemon.usage.projection": ["BurnBarUsageProjectionRequest", "BurnBarUsageProjectionResponse"],
  "daemon.usage.recount": ["BurnBarUsageRecountRequest", "BurnBarUsageProjectionResponse"],
  "client.attach": ["BurnBarClientAttachRequest", "BurnBarClientAttachResponse"],
  "client.claimControl": ["BurnBarClientClaimControlRequest", "BurnBarClientArbitrationSnapshot"],
  "client.detach": ["BurnBarClientDetachRequest", "BurnBarClientArbitrationSnapshot"],
  "run.create": ["BurnBarRunCreateRequest", "BurnBarRunCreateResponse"],
  "run.list": ["BurnBarRunListRequest", "BurnBarRunListResponse"],
  "run.get": ["BurnBarRunGetRequest", "BurnBarRunDetailResponse"],
  "run.poll": ["BurnBarRunPollRequest", "BurnBarRunEventBatch"],
  "run.cancel": ["BurnBarRunCancelRequest", "BurnBarRunDetailResponse"],
  "run.retry": ["BurnBarRunRetryRequest", "BurnBarRunDetailResponse"],
  "run.resume": ["BurnBarRunResumeRequest", "BurnBarRunResumeResponse"],
  "workspace.executeTool": ["BurnBarToolExecutionRequest", "BurnBarToolExecutionResponse"],
  "workspace.toolResult": ["BurnBarToolResultSubmissionRequest", "BurnBarRunDetailResponse"],
  "approval.respond": ["BurnBarApprovalRespondRequest", "BurnBarRunDetailResponse"],
  "subscription.start": ["BurnBarSubscriptionStartRequest", "BurnBarSubscriptionResponse"],
  "subscription.resume": ["BurnBarSubscriptionResumeRequest", "BurnBarSubscriptionResponse"],
  "subscription.stop": ["BurnBarSubscriptionStopRequest", "BurnBarSubscriptionStopResponse"],
  "daemon.database.recovery.status": ["BurnBarRPCRequestEnvelope", "BurnBarDatabaseRecoveryStatusResponse"],
  "daemon.database.recovery_bundle.export": ["BurnBarDatabaseRecoveryBundleExportRequest", "BurnBarDatabaseRecoveryBundleExportResponse"],
  "daemon.database.recovery_bundle.import": ["BurnBarDatabaseRecoveryBundleImportRequest", "BurnBarDatabaseRecoveryBundleImportResponse"]
};

function inferTypes(method) {
  if (explicitTypes[method.id]) return explicitTypes[method.id];
  const family = method.id.split(".").slice(0, -1).join(".");
  if (method.id.endsWith(".get") || method.id.endsWith(".list") || method.id.endsWith(".recent")) {
    return ["BurnBarRPCRequestEnvelopeWithParams<Codable request>", `Codable response for ${family}`];
  }
  if (method.id.includes(".create") || method.id.includes(".update") || method.id.includes(".remove") || method.id.includes(".record") || method.id.includes(".respond")) {
    return ["BurnBarRPCRequestEnvelopeWithParams<Codable request>", `Codable mutation response for ${family}`];
  }
  return ["BurnBarRPCRequestEnvelopeWithParams<Codable request>", `Codable response for ${method.id}`];
}

function buildCanon() {
  const methods = parseMethods(read(files.contracts));
  const capabilities = parseCapabilities(read(files.capability));
  const domains = parseDomains(read(files.coverage));
  const rows = methods.map((method) => {
    const capability = capabilities.get(method.caseName);
    const domain = domains.get(method.caseName);
    if (!capability) throw new Error(`Missing capability mapping for ${method.caseName} (${method.id})`);
    if (!domain) throw new Error(`Missing handler domain mapping for ${method.caseName} (${method.id})`);
    const [params, result] = inferTypes(method);
    return {
      id: method.id,
      caseName: method.caseName,
      domain,
      capability,
      owner: "OpenBurnBarDaemon",
      params,
      result,
      error: "BurnBarRPCError"
    };
  });
  return rows.sort((left, right) => left.id.localeCompare(right.id));
}

function swiftString(value) {
  return JSON.stringify(value);
}

function renderSwift(rows) {
  const entries = rows.map((row) => `        BurnBarRPCIPCCanonEntry(id: ${swiftString(row.id)}, caseName: ${swiftString(row.caseName)}, domain: ${swiftString(row.domain)}, capability: ${swiftString(row.capability)}, owner: ${swiftString(row.owner)}, params: ${swiftString(row.params)}, result: ${swiftString(row.result)}, error: ${swiftString(row.error)})`).join(",\n");
  return `// Generated by tools/ipc/generate-burnbarrpc-canon.mjs. Do not edit by hand.\nimport Foundation\n\npublic struct BurnBarRPCIPCCanonEntry: Codable, Hashable, Sendable {\n    public let id: String\n    public let caseName: String\n    public let domain: String\n    public let capability: String\n    public let owner: String\n    public let params: String\n    public let result: String\n    public let error: String\n}\n\npublic enum BurnBarRPCIPCCanon {\n    public static let methods: [BurnBarRPCIPCCanonEntry] = [\n${entries}\n    ]\n}\n`;
}

function renderTypescript(rows) {
  return `// Generated by tools/ipc/generate-burnbarrpc-canon.mjs. Do not edit by hand.\nexport type BurnBarRpcIpcCanonEntry = {\n  id: string;\n  caseName: string;\n  domain: string;\n  capability: string;\n  owner: string;\n  params: string;\n  result: string;\n  error: string;\n};\n\nexport const burnBarRpcIpcCanon = ${JSON.stringify(rows, null, 2)} as const satisfies readonly BurnBarRpcIpcCanonEntry[];\n`;
}

function renderJson(rows) {
  return JSON.stringify({
    generatedBy: "tools/ipc/generate-burnbarrpc-canon.mjs",
    methodCount: rows.length,
    methods: rows
  }, null, 2) + "\n";
}

function ensureParent(file) {
  mkdirSync(path.dirname(file), { recursive: true });
}

function writeOrCheck(file, content) {
  if (check) {
    if (!existsSync(file)) {
      console.error(`missing generated file: ${path.relative(root, file)}`);
      process.exitCode = 1;
      return;
    }
    const existing = read(file);
    if (existing !== content) {
      console.error(`drift detected: ${path.relative(root, file)}`);
      process.exitCode = 1;
    }
    return;
  }
  ensureParent(file);
  writeFileSync(file, content);
}

function verifyFixture(rows, fixture) {
  const raw = JSON.parse(read(fixture));
  const expectedIDs = Array.isArray(raw)
    ? raw.map((entry) => typeof entry === "string" ? entry : entry.id)
    : raw.methods.map((entry) => typeof entry === "string" ? entry : entry.id);
  const actual = new Set(rows.map((row) => row.id));
  const expected = new Set(expectedIDs);
  const missing = [...actual].filter((id) => !expected.has(id)).sort();
  const extra = [...expected].filter((id) => !actual.has(id)).sort();
  if (missing.length || extra.length) {
    console.error(JSON.stringify({ ok: false, missing, extra }, null, 2));
    process.exit(1);
  }
  console.log(JSON.stringify({ ok: true, methodCount: actual.size }, null, 2));
}

const rows = buildCanon();
if (fixturePath) {
  verifyFixture(rows, path.resolve(root, fixturePath));
}
writeOrCheck(files.swift, renderSwift(rows));
writeOrCheck(files.typescript, renderTypescript(rows));
writeOrCheck(files.json, renderJson(rows));
if (process.exitCode) {
  process.exit(process.exitCode);
}
if (!check) {
  console.log(`Generated BurnBarRPC IPC canon for ${rows.length} methods.`);
}
