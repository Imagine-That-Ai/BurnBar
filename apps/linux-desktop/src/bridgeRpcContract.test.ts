import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const rustBridge = fs.readFileSync(path.join(here, '../src-tauri/src/lib.rs'), 'utf8');
const tsBridge = fs.readFileSync(path.join(here, 'tauriBridge.ts'), 'utf8');
const canonicalRpc = fs.readFileSync(
  path.join(here, '../../../OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCIPCCanon.generated.swift'),
  'utf8'
);

/** Invented method families that must not appear unless added to BurnBarRPCMethod. */
const FORBIDDEN_RAW = [
  'daemon.hermes.',
  'daemon.mercury.',
  'daemon.smarthub.',
  'daemon.textexpansion.',
  'daemon.memory.review_legacy'
];

/** Strip // line comments and /* block comments for RPC string greps. */
function stripComments(source: string): string {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
}

/** Extract call_daemon_method("...") targets only. */
function daemonMethodCalls(source: string): string[] {
  const re = /call_daemon_method\(\s*"([^"]+)"/g;
  const out: string[] = [];
  let m: RegExpExecArray | null;
  const live = stripComments(source);
  while ((m = re.exec(live))) {
    out.push(m[1]!);
  }
  return out;
}

describe('VAL-RPC bridge contract', () => {
  it('does not invent forbidden daemon method strings (VAL-RPC-001)', () => {
    const calls = daemonMethodCalls(rustBridge);
    for (const needle of FORBIDDEN_RAW) {
      expect(
        calls.some((c) => c.startsWith(needle) || c.includes(needle)),
        `lib.rs must not call_daemon_method ${needle}`
      ).toBe(false);
    }
    const tsLive = stripComments(tsBridge);
    for (const needle of FORBIDDEN_RAW) {
      expect(tsLive.includes(needle), `tauriBridge.ts must not call ${needle}`).toBe(false);
    }
  });

  it('wires tool approval to approval.respond', () => {
    expect(rustBridge).toContain('approval.respond');
    expect(rustBridge).toContain('fn tool_approval_respond');
    expect(tsBridge).toContain('tool_approval_respond');
  });

  it('encodes respondedAt as Foundation reference-date seconds (f64)', () => {
    expect(rustBridge).toContain('foundation_reference_date_seconds');
    expect(rustBridge).toContain('978_307_200');
    // Must not emit RFC3339 ISO strings for approval timestamps.
    expect(rustBridge).not.toContain('format_unix_as_rfc3339');
    expect(rustBridge).not.toContain('fn iso8601_now');
  });

  it('wires memory quarantine/review status to canonical daemon RPCs', () => {
    expect(rustBridge).toContain('daemon.memory.remember');
    expect(rustBridge).toContain('daemon.memory.review_status');
    expect(rustBridge).toContain('daemon.memory.forget');
    expect(rustBridge).toContain('daemon.memory.audit_trail');
    expect(rustBridge).toContain('fn memory_set_status');
    expect(tsBridge).toContain('memory_set_status');
    expect(canonicalRpc).toContain('id: "daemon.memory.review_status"');
  });

  it('wires bounded database retrieval only to canonical code RPCs', () => {
    expect(rustBridge).toContain('daemon.code.search');
    expect(rustBridge).toContain('daemon.code.context_pack');
    expect(rustBridge).toContain('fn database_code_search');
    expect(rustBridge).toContain('fn database_code_context_pack');
    expect(tsBridge).toContain("'database_code_search'");
    expect(tsBridge).toContain("'database_code_context_pack'");
    expect(canonicalRpc).toContain('id: "daemon.code.search"');
    expect(canonicalRpc).toContain('id: "daemon.code.context_pack"');
  });

  it('wires encrypted database snapshot and restore to canonical code RPCs', () => {
    expect(rustBridge).toContain('daemon.code.database_snapshot');
    expect(rustBridge).toContain('daemon.code.database_restore');
    expect(rustBridge).toContain('fn database_snapshot');
    expect(rustBridge).toContain('fn database_restore');
    expect(tsBridge).toContain("'database_snapshot'");
    expect(tsBridge).toContain("'database_restore'");
    expect(canonicalRpc).toContain('id: "daemon.code.database_snapshot"');
    expect(canonicalRpc).toContain('id: "daemon.code.database_restore"');
  });

  it('wires database recovery only to canonical daemon-owned RPCs', () => {
    expect(rustBridge).toContain('daemon.database.recovery.status');
    expect(rustBridge).toContain('daemon.database.recovery_bundle.export');
    expect(rustBridge).toContain('daemon.database.recovery_bundle.import');
    expect(rustBridge).toContain('fn database_recovery_bundle_status');
    expect(rustBridge).toContain('fn database_recovery_bundle_export');
    expect(rustBridge).toContain('fn database_recovery_bundle_import');
    expect(tsBridge).toContain("'database_recovery_bundle_export'");
    expect(tsBridge).toContain("'database_recovery_bundle_import'");
    expect(tsBridge).toContain("'database_recovery_bundle_status'");
    expect(canonicalRpc).toContain('id: "daemon.database.recovery.status"');
    expect(canonicalRpc).toContain('id: "daemon.database.recovery_bundle.export"');
    expect(canonicalRpc).toContain('id: "daemon.database.recovery_bundle.import"');
  });

  it('wires computer use wrappers to existing enum methods', () => {
    for (const method of [
      'daemon.computer_use.session.start',
      'daemon.computer_use.session_grant.acquire',
      'daemon.computer_use.session_grant.status',
      'daemon.computer_use.invoke',
      'daemon.computer_use.approval.pending',
      'daemon.computer_use.approval.respond',
      'daemon.computer_use.panic_halt',
      'daemon.computer_use.audit_export'
    ]) {
      expect(rustBridge).toContain(method);
    }
    expect(rustBridge).toContain('fn computer_use_session_start');
    expect(tsBridge).toContain('computer_use_session_start');
  });

  it('wires media commands only to canonical daemon RPC methods', () => {
    const mediaCalls = daemonMethodCalls(rustBridge).filter((method) =>
      method.startsWith('daemon.media.')
    );
    expect(mediaCalls).toContain('daemon.media.status');
    expect(mediaCalls).toContain('daemon.media.session.state');
    expect(mediaCalls).toContain('daemon.media.call.accept');
    expect(mediaCalls).toContain('daemon.media.file.send');
    for (const method of new Set(mediaCalls)) {
      expect(canonicalRpc, `${method} must exist in BurnBarRPCIPCCanon`).toContain(`id: "${method}"`);
    }
  });

  it('keeps SmartHub execution on the fixed Linux CLI allowlist', () => {
    expect(rustBridge).toContain('fn smarthub_command');
    for (const operation of ['discover', 'status', 'cast_status', 'homeassistant_status', 'parity']) {
      expect(rustBridge).toContain(`"${operation}"`);
    }
    expect(rustBridge).toContain('smarthub_operation_not_allowlisted');
    expect(tsBridge).toContain("invoke<RawJsonValue>('smarthub_command'");
    expect(tsBridge).not.toContain('runCli');
  });

  it('routes text expansion through typed daemon RPC methods', () => {
    expect(rustBridge).toContain('fn text_expansion_list');
    expect(rustBridge).toContain('fn text_expansion_upsert');
    expect(rustBridge).toContain('fn text_expansion_delete');
    expect(rustBridge).toContain('fn text_expansion_engine_status');
    expect(rustBridge).toContain('fn text_expansion_engine_start');
    expect(rustBridge).toContain('fn text_expansion_engine_stop');
    expect(tsBridge).toContain("'text_expansion_list'");
    expect(tsBridge).toContain("'text_expansion_upsert'");
    expect(tsBridge).toContain("'text_expansion_delete'");
    expect(tsBridge).toContain("'text_expansion_consent_update'");
    expect(tsBridge).toContain("'text_expansion_engine_status'");
    expect(tsBridge).toContain("'text_expansion_engine_start'");
    expect(tsBridge).toContain("'text_expansion_engine_stop'");
    for (const method of [
      'daemon.text_expansion.get',
      'daemon.text_expansion.upsert',
      'daemon.text_expansion.delete',
      'daemon.text_expansion.consent.update',
      'daemon.text_expansion.engine.status',
      'daemon.text_expansion.engine.start',
      'daemon.text_expansion.engine.stop'
    ]) {
      expect(rustBridge).toContain(method);
      expect(canonicalRpc).toContain(`id: "${method}"`);
    }
  });

  it('wires daemon-owned Linux auth without renderer credential material', () => {
    for (const method of [
      'daemon.auth.status',
      'daemon.auth.begin',
      'daemon.auth.cancel',
      'daemon.auth.rotate_identity',
      'daemon.auth.sign_out'
    ]) {
      expect(rustBridge).toContain(method);
      expect(canonicalRpc, `${method} must exist in BurnBarRPCIPCCanon`).toContain(`id: "${method}"`);
    }
    expect(rustBridge).toContain('object.remove("authorizationURL")');
    const accountTypes = tsBridge.slice(
      tsBridge.indexOf('P08: account'),
      tsBridge.indexOf('P10: membership')
    );
    expect(accountTypes).not.toMatch(/\b(refreshToken|idToken|appCheckToken|sessionGeneration|deviceID)\b/);
  });

  it('wires exact-thread chat only to canonical daemon RPC methods', () => {
    for (const method of [
      'daemon.chat.thread.list',
      'daemon.chat.thread.get',
      'daemon.chat.message.append'
    ]) {
      expect(rustBridge).toContain(method);
      expect(canonicalRpc, `${method} must exist in BurnBarRPCIPCCanon`).toContain(`id: "${method}"`);
    }
    expect(rustBridge).toContain('fn chat_thread_list');
    expect(rustBridge).toContain('fn chat_thread_get');
    expect(rustBridge).toContain('fn chat_message_append');
    expect(tsBridge).toContain('chat_thread_list');
    expect(tsBridge).toContain('chat_thread_get');
    expect(tsBridge).toContain('chat_message_append');
  });

  it('keeps chat attachment upload daemon-owned and path-free', () => {
    expect(rustBridge).toContain('fn chat_attachment_upload');
    expect(rustBridge).toContain('CHAT_ATTACHMENT_MAX_BYTES');
    expect(rustBridge).toContain('chat_attachment_unsupported');
    expect(tsBridge).toContain("'chat_attachment_upload'");
    expect(tsBridge).toContain('must not expose a filesystem path');
  });

  it('wires project lifecycle operations only to canonical controller RPCs', () => {
    for (const method of [
      'daemon.controller.project.list',
      'daemon.controller.project.get',
      'daemon.controller.project.upsert',
      'daemon.controller.project.delete',
      'daemon.controller.project.reassign'
    ]) {
      expect(rustBridge).toContain(method);
      expect(canonicalRpc, `${method} must exist in BurnBarRPCIPCCanon`).toContain(`id: "${method}"`);
    }
    expect(tsBridge).toContain('projectGet');
    expect(tsBridge).toContain('projectUpsert');
    expect(tsBridge).toContain('projectDelete');
    expect(tsBridge).toContain('projectReassign');
  });

  it('wires Activity persisted body and resume actions through the existing run.resume contract', () => {
    expect(rustBridge).toContain('run.resume');
    expect(rustBridge).toContain('fn session_replay');
    expect(rustBridge).toContain('fn session_resume');
    expect(tsBridge).toContain("'session_replay'");
    expect(tsBridge).toContain("'session_resume'");
    expect(canonicalRpc).toContain('id: "run.resume"');
  });

  it('wires mission detail and explicit cancellation only to canonical RPCs', () => {
    for (const method of ['daemon.mission.list', 'daemon.mission.get', 'daemon.mission.create', 'daemon.mission.approve', 'daemon.mission.cancel']) {
      expect(rustBridge).toContain(method);
      expect(canonicalRpc, `${method} must exist in BurnBarRPCIPCCanon`).toContain(`id: "${method}"`);
    }
    expect(tsBridge).toContain('mission_get');
    expect(tsBridge).toContain('mission_cancel');
  });
});
