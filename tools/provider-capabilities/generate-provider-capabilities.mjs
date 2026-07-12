#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2);
const check = args.includes('--check');
const manifestFlag = args.indexOf('--manifest');
if (manifestFlag >= 0 && !args[manifestFlag + 1]) throw new Error('--manifest requires a path');
const manifestPath = path.resolve(root, manifestFlag >= 0 ? args[manifestFlag + 1] : 'tools/provider-capabilities/provider-capabilities.json');
const outputs = {
  swift: path.join(root, 'OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AgentProviderCapabilities.generated.swift'),
  typescript: path.join(root, 'apps/linux-desktop/src/generated/providerCapabilities.generated.ts')
};
const allowedXDG = new Set(['home-relative', 'xdg-config', 'xdg-data', 'no-local-logs']);

function validateManifest(manifest) {
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.providers) || manifest.providers.length === 0) {
    throw new Error('manifest must have schemaVersion 1 and a non-empty providers array');
  }
  if (manifest.symlinkIdentityBehavior !== 'standardized-logical-path') {
    throw new Error('symlinkIdentityBehavior must be standardized-logical-path');
  }
  for (const key of ['noLocalLogs', 'pathWithoutParser', 'noQuota', 'noChat', 'noAccountConnect']) {
    if (typeof manifest.unsupportedReasonCatalog?.[key] !== 'string' || manifest.unsupportedReasonCatalog[key].trim() === '') {
      throw new Error(`unsupportedReasonCatalog.${key} must be non-empty`);
    }
  }
  const cases = new Set();
  const ids = new Set();
  for (const row of manifest.providers) {
    for (const key of ['providerCase', 'providerId', 'displayName', 'xdgBehavior']) {
      if (typeof row[key] !== 'string' || row[key].trim() === '') throw new Error(`${row.providerCase ?? '<unknown>'}: ${key} must be non-empty`);
    }
    if (cases.has(row.providerCase)) throw new Error(`duplicate providerCase: ${row.providerCase}`);
    if (ids.has(row.providerId)) throw new Error(`duplicate providerId: ${row.providerId}`);
    cases.add(row.providerCase); ids.add(row.providerId);
    if (!allowedXDG.has(row.xdgBehavior)) throw new Error(`${row.providerCase}: invalid xdgBehavior ${row.xdgBehavior}`);
    for (const key of ['quota', 'accountConnect']) {
      if (typeof row[key] !== 'boolean') throw new Error(`${row.providerCase}: ${key} must be boolean`);
    }
    if (row.chatRuntimeId !== null && (typeof row.chatRuntimeId !== 'string' || row.chatRuntimeId === '')) throw new Error(`${row.providerCase}: invalid chatRuntimeId`);
    const pathFields = [row.linuxLogicalPath, row.macOSLogicalPath, row.filePattern];
    const noLocalLogs = row.xdgBehavior === 'no-local-logs';
    const validPaths = noLocalLogs
      ? pathFields.every((value) => value === null)
      : pathFields.every((value) => typeof value === 'string' && value.length > 0);
    if (!validPaths) throw new Error(`${row.providerCase}: no-local-logs requires null paths and pattern, while path rows require all three`);
    if (row.parserSource !== null && noLocalLogs) throw new Error(`${row.providerCase}: parserSource cannot be set for no-local-logs`);
  }
  return manifest.providers;
}

function reason(row, capability, catalog) {
  if (capability === 'localLogs' && row.parserSource === null) return row.xdgBehavior === 'no-local-logs' ? catalog.noLocalLogs : catalog.pathWithoutParser;
  if (capability === 'quota' && !row.quota) return catalog.noQuota;
  if (capability === 'chat' && row.chatRuntimeId === null) return catalog.noChat;
  if (capability === 'accountConnect' && !row.accountConnect) return catalog.noAccountConnect;
  return null;
}

function normalize(manifest) {
  const catalog = manifest.unsupportedReasonCatalog;
  return manifest.providers.map((row) => ({ ...row, symlinkIdentityBehavior: manifest.symlinkIdentityBehavior, unsupportedReasons: {
    localLogs: reason(row, 'localLogs', catalog), quota: reason(row, 'quota', catalog), chat: reason(row, 'chat', catalog), accountConnect: reason(row, 'accountConnect', catalog)
  }}));
}

const q = JSON.stringify;
const swiftOptional = (value) => value === null ? 'nil' : q(value);
function renderSwift(rows) {
  const entries = rows.map((r) => `        .${r.providerCase}: AgentProviderCapabilityRecord(provider: .${r.providerCase}, providerID: ${q(r.providerId)}, displayName: ${q(r.displayName)}, parserSource: ${swiftOptional(r.parserSource)}, linuxLogicalPath: ${swiftOptional(r.linuxLogicalPath)}, macOSLogicalPath: ${swiftOptional(r.macOSLogicalPath)}, filePattern: ${swiftOptional(r.filePattern)}, xdgBehavior: .${r.xdgBehavior.replace(/-([a-z])/g, (_, c) => c.toUpperCase())}, symlinkIdentityBehavior: .standardizedLogicalPath, quotaSupported: ${r.quota}, chatRuntimeID: ${swiftOptional(r.chatRuntimeId)}, accountConnectSupported: ${r.accountConnect}, unsupportedReasons: .init(localLogs: ${swiftOptional(r.unsupportedReasons.localLogs)}, quota: ${swiftOptional(r.unsupportedReasons.quota)}, chat: ${swiftOptional(r.unsupportedReasons.chat)}, accountConnect: ${swiftOptional(r.unsupportedReasons.accountConnect)}))`).join(',\n');
  return [
    '// Generated by tools/provider-capabilities/generate-provider-capabilities.mjs. Do not edit.',
    'import Foundation', '',
    'public enum AgentProviderXDGBehavior: String, Codable, Sendable { case homeRelative, xdgConfig, xdgData, noLocalLogs }',
    'public enum AgentProviderSymlinkIdentityBehavior: String, Codable, Sendable { case standardizedLogicalPath }',
    'public struct AgentProviderUnsupportedReasons: Codable, Hashable, Sendable { public let localLogs: String?; public let quota: String?; public let chat: String?; public let accountConnect: String? }',
    'public struct AgentProviderCapabilityRecord: Codable, Hashable, Sendable {',
    '    public let provider: AgentProvider; public let providerID: String; public let displayName: String; public let parserSource: String?',
    '    public let linuxLogicalPath: String?; public let macOSLogicalPath: String?; public let filePattern: String?; public let xdgBehavior: AgentProviderXDGBehavior',
    '    public let symlinkIdentityBehavior: AgentProviderSymlinkIdentityBehavior; public let quotaSupported: Bool; public let chatRuntimeID: String?; public let accountConnectSupported: Bool; public let unsupportedReasons: AgentProviderUnsupportedReasons',
    '    public var localLogsSupported: Bool { parserSource != nil }',
    '    public var logicalPath: String? {',
    '        #if os(Linux)', '        linuxLogicalPath', '        #else', '        macOSLogicalPath', '        #endif', '    }', '}',
    'public enum AgentProviderCapabilities {',
    '    public static let byProvider: [AgentProvider: AgentProviderCapabilityRecord] = [', entries, '    ]',
    '    public static let all: [AgentProviderCapabilityRecord] = AgentProvider.allCases.compactMap { byProvider[$0] }', '}',
    'public extension AgentProvider { var capabilityRecord: AgentProviderCapabilityRecord { AgentProviderCapabilities.byProvider[self]! } }', ''
  ].join('\n');
}

function renderTypeScript(rows) {
  return `// Generated by tools/provider-capabilities/generate-provider-capabilities.mjs. Do not edit.\nexport type ProviderCapabilityRow = { providerCase: string; providerId: string; displayName: string; parserSource: string | null; linuxLogicalPath: string | null; macOSLogicalPath: string | null; filePattern: string | null; xdgBehavior: 'home-relative' | 'xdg-config' | 'xdg-data' | 'no-local-logs'; symlinkIdentityBehavior: 'standardized-logical-path'; quota: boolean; chatRuntimeId: string | null; accountConnect: boolean; unsupportedReasons: { localLogs: string | null; quota: string | null; chat: string | null; accountConnect: string | null } };\nexport const PROVIDER_CAPABILITIES = ${JSON.stringify(rows, null, 2)} as const satisfies readonly ProviderCapabilityRow[];\n`;
}

function writeOrCheck(file, content) {
  if (check) {
    if (!existsSync(file) || readFileSync(file, 'utf8') !== content) { console.error(`drift detected: ${path.relative(root, file)}`); process.exitCode = 1; }
  } else { mkdirSync(path.dirname(file), { recursive: true }); writeFileSync(file, content); }
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
validateManifest(manifest);
const rows = normalize(manifest);
writeOrCheck(outputs.swift, renderSwift(rows));
writeOrCheck(outputs.typescript, renderTypeScript(rows));
if (!check) console.log(`Generated provider capability outputs for ${rows.length} providers.`);
