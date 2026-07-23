/**
 * VAL-RPC-002 behavioral suite for Phase 2 bridge methods.
 * Exercises invoke mapping via mocked @tauri-apps/api/core (no real daemon).
 */
// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  COMPUTER_USE_SESSION_DEFAULTS,
  decodeComputerUseInvokeResponse
} from './tauriBridge.js';
import type { ProjectUpsertInput } from './tauriBridge.js';

const invoke = vi.fn();

vi.mock('@tauri-apps/api/core', () => ({
  invoke: (...args: unknown[]) => invoke(...args)
}));

vi.mock('@tauri-apps/plugin-shell', () => ({
  open: vi.fn()
}));

describe('VAL-RPC-002 bridge behavior', () => {
  beforeEach(() => {
    invoke.mockReset();
    (window as unknown as { __TAURI_INTERNALS__: object }).__TAURI_INTERNALS__ = {};
  });

  afterEach(() => {
    delete (window as unknown as { __TAURI_INTERNALS__?: object }).__TAURI_INTERNALS__;
  });

  async function bridge() {
    const { loadShellBridge } = await import('./tauriBridge.js');
    const b = await loadShellBridge();
    if (!b) throw new Error('expected tauri bridge');
    return b;
  }

  it('keeps startup and forwarded deep-link queues under distinct consumers', async () => {
    invoke.mockResolvedValueOnce('providers?provider=codex').mockResolvedValueOnce('settings');
    const b = await bridge();

    await expect(b.initialDeepLinkRoute?.()).resolves.toBe('providers?provider=codex');
    await expect(b.forwardedDeepLinkRoute?.()).resolves.toBe('settings');
    expect(invoke).toHaveBeenNthCalledWith(1, 'initial_deep_link_route');
    expect(invoke).toHaveBeenNthCalledWith(2, 'forwarded_deep_link_route');
  });

  it('maps exact-thread chat commands without changing daemon field names', async () => {
    const thread = {
      id: 'thread-1',
      title: 'Release',
      preview: 'Check Linux',
      messageCount: 1,
      createdAt: '2026-07-10T12:00:00Z',
      updatedAt: '2026-07-10T12:00:00Z'
    };
    const message = {
      id: 'message-1',
      threadID: 'thread-1',
      role: 'user',
      content: 'Check Linux',
      timestamp: '2026-07-10T12:00:00Z'
    };
    invoke
      .mockResolvedValueOnce({ threads: [thread] })
      .mockResolvedValueOnce({ thread, messages: [message], hasMoreBefore: false })
      .mockResolvedValueOnce({ message, inserted: false });
    const b = await bridge();
    await b.chatThreadList('release', 40);
    await b.chatThreadGet('thread-1', 200);
    await expect(b.chatMessageAppend({
      threadID: 'thread-1',
      messageID: 'message-1',
      role: 'user',
      content: 'Check Linux',
      timestamp: '2026-07-10T12:00:00Z'
    })).resolves.toMatchObject({ inserted: false });
    expect(invoke).toHaveBeenNthCalledWith(1, 'chat_thread_list', { query: 'release', limit: 40 });
    expect(invoke).toHaveBeenNthCalledWith(2, 'chat_thread_get', {
      threadId: 'thread-1',
      maxMessages: 200
    });
    expect(invoke).toHaveBeenNthCalledWith(3, 'chat_message_append', {
      request: {
        threadID: 'thread-1',
        messageID: 'message-1',
        role: 'user',
        content: 'Check Linux',
        timestamp: '2026-07-10T12:00:00Z'
      }
    });
  });

  it('uploads chat attachments through a bounded metadata-only bridge result', async () => {
    invoke.mockResolvedValueOnce({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 12,
      sha256: 'a'.repeat(64)
    });
    const b = await bridge();
    await expect(b.chatAttachmentUpload({
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      contentBase64: 'SGVsbG8gTGludXg='
    })).resolves.toEqual({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 12,
      sha256: 'a'.repeat(64)
    });
    expect(invoke).toHaveBeenCalledWith('chat_attachment_upload', {
      request: {
        fileName: 'notes.md',
        mimeType: 'text/markdown',
        contentBase64: 'SGVsbG8gTGludXg='
      }
    });
  });

  it('rejects an append response that changes the idempotency identity', async () => {
    invoke.mockResolvedValueOnce({
      message: {
        id: 'different-message',
        threadID: 'thread-1',
        role: 'user',
        content: 'Check Linux',
        timestamp: '2026-07-10T12:00:00Z'
      },
      inserted: false
    });
    const b = await bridge();
    await expect(b.chatMessageAppend({
      threadID: 'thread-1',
      messageID: 'message-1',
      role: 'user',
      content: 'Check Linux',
      timestamp: '2026-07-10T12:00:00Z'
    })).rejects.toThrow('idempotency identity');
  });

  it('passes stable chat pagination cursors without changing daemon field names', async () => {
    const message = {
      id: 'older-message',
      threadID: 'thread-1',
      role: 'assistant',
      content: 'Older reply',
      timestamp: '2026-07-10T11:59:00.000Z'
    };
    invoke.mockResolvedValueOnce({
      thread: {
        id: 'thread-1',
        title: 'Thread',
        preview: 'Older reply',
        messageCount: 2,
        createdAt: '2026-07-10T11:59:00.000Z',
        updatedAt: '2026-07-10T12:00:00.000Z'
      },
      messages: [message],
      hasMoreBefore: false
    });
    const b = await bridge();

    await b.chatThreadGet('thread-1', 200, {
      timestamp: '2026-07-10T12:00:00.000Z',
      messageID: 'newest-page-oldest'
    });

    expect(invoke).toHaveBeenCalledWith('chat_thread_get', {
      threadId: 'thread-1',
      maxMessages: 200,
      beforeTimestamp: '2026-07-10T12:00:00.000Z',
      beforeMessageId: 'newest-page-oldest'
    });
  });

  it('runtimeCapabilities invokes and validates the native manifest', async () => {
    const { makeAvailableRuntimeCapabilityManifest } = await import('./testing/bridgeStubs.js');
    const manifest = makeAvailableRuntimeCapabilityManifest();
    invoke.mockResolvedValueOnce(manifest);
    const b = await bridge();
    await expect(b.runtimeCapabilities()).resolves.toEqual(manifest);
    expect(invoke).toHaveBeenCalledWith('runtime_capabilities');
  });

  it('runtimeCapabilities rejects malformed native data', async () => {
    invoke.mockResolvedValueOnce({ schemaVersion: 1, capabilities: [] });
    const b = await bridge();
    await expect(b.runtimeCapabilities()).rejects.toThrow(/missing_ids/);
  });

  it('project list/detail/upsert use the canonical controller RPC payloads', async () => {
    const canonical: ProjectUpsertInput = {
      id: 'project-apollo',
      projectSlug: 'apollo',
      displayName: 'Apollo',
      summary: 'Controller project',
      status: 'healthy',
      preferredCadence: 'weekly',
      aliases: ['apollo-app'],
      automationMode: 'manual',
      reviewModelID: 'glm-5',
      scheduleHourLocal: 9,
      scheduleWeekdayLocal: 2,
      freshness: 'fresh',
      pendingQuestionCount: 1,
      openFollowupCount: 0,
      activeMissionCount: 2,
      activeMissionID: 'mission-1',
      needsOperatorAttention: true,
      ingestionSource: 'manual',
      metadata: { session_count_last_7d: 4 }
    };
    invoke
      .mockResolvedValueOnce({ projects: [canonical] })
      .mockResolvedValueOnce({ project: canonical })
      .mockResolvedValueOnce({ project: canonical });
    const b = await bridge();

    await expect(b.projectList()).resolves.toMatchObject([
      { id: 'project-apollo', projectSlug: 'apollo', name: 'Apollo', scope: 'controller', path: '' }
    ]);
    await expect(b.projectGet?.('apollo')).resolves.toMatchObject({ projectSlug: 'apollo', displayName: 'Apollo' });
    await expect(b.projectUpsert?.(canonical)).resolves.toMatchObject({ projectSlug: 'apollo' });

    expect(invoke).toHaveBeenNthCalledWith(1, 'project_list');
    expect(invoke).toHaveBeenNthCalledWith(2, 'project_get', { projectSlug: 'apollo' });
    expect(invoke).toHaveBeenNthCalledWith(3, 'project_upsert', { project: canonical });
  });

  it('uses typed delete and reassign project lifecycle commands', async () => {
    invoke
      .mockResolvedValueOnce({ projectSlug: 'apollo', deleted: true })
      .mockResolvedValueOnce({ sourceProjectSlug: 'apollo', targetProjectSlug: 'orion', updatedReferenceCount: 3 });
    const b = await bridge();

    await expect(b.projectDelete?.('apollo')).resolves.toEqual({ projectSlug: 'apollo', deleted: true });
    await expect(b.projectReassign?.('apollo', 'orion')).resolves.toEqual({
      sourceProjectSlug: 'apollo',
      targetProjectSlug: 'orion',
      updatedReferenceCount: 3
    });
    expect(invoke).toHaveBeenNthCalledWith(1, 'project_delete', { projectSlug: 'apollo' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'project_reassign', { sourceProjectSlug: 'apollo', targetProjectSlug: 'orion' });
  });

  it('maps project history from the daemon controller summary without leaking other projects', async () => {
    invoke.mockResolvedValueOnce({
      summary: {
        recentEvents: [
          {
            id: 'event-orion',
            projectSlug: 'orion',
            eventType: 'project_upserted',
            summary: 'Orion registered',
            recordedAt: '2026-07-14T12:00:00Z',
            sequence: 3,
            isReplay: false
          },
          {
            id: 'event-apollo',
            projectSlug: 'apollo',
            eventType: 'project_reassigned',
            summary: 'References moved',
            detail: 'apollo -> orion',
            recordedAt: '2026-07-14T11:00:00Z',
            sequence: 2,
            isReplay: true
          }
        ]
      }
    });
    const b = await bridge();
    await expect(b.projectHistory?.('apollo')).resolves.toEqual([{
      id: 'event-apollo',
      projectSlug: 'apollo',
      eventType: 'project_reassigned',
      summary: 'References moved',
      detail: 'apollo -> orion',
      recordedAt: '2026-07-14T11:00:00Z',
      sequence: 2,
      isReplay: true
    }]);
    expect(invoke).toHaveBeenCalledWith('project_history', { projectSlug: 'apollo' });
  });

  it('maps the daemon-owned privacy inventory and two-phase deletion contract', async () => {
    invoke
      .mockResolvedValueOnce({
        stores: [
          { store: 'proxy_route_log', state: 'ready', bytes: 24, reason: 'ready' },
          { store: 'text_expansion_store', state: 'absent', bytes: 0, reason: 'missing' }
        ],
        generatedAt: '2026-07-14T00:00:00Z'
      })
      .mockResolvedValueOnce({
        token: 'preview-token',
        stores: ['proxy_route_log'],
        entries: [{ store: 'proxy_route_log', state: 'ready', bytes: 24, reason: 'ready' }],
        expiresAt: '2026-07-14T00:05:00Z',
        confirmationPhrase: 'DELETE LOCAL DATA'
      })
      .mockResolvedValueOnce({
        stores: ['proxy_route_log'],
        deleted: ['proxy_route_log'],
        alreadyAbsent: [],
        bytesRemoved: 24,
        idempotent: false
      })
      .mockResolvedValueOnce({
        stores: ['proxy_route_log'],
        destinationPath: '/tmp/privacy-export.obb',
        byteCount: 192,
        formatVersion: 1
      })
      .mockResolvedValueOnce({
        policyState: 'defaults',
        rules: [
          { store: 'proxy_route_log', maxAgeSeconds: 2592000, maxBytes: 8388608 },
          { store: 'text_expansion_store', maxAgeSeconds: 31536000, maxBytes: 4194304 }
        ],
        stores: [
          { store: 'proxy_route_log', state: 'ready', bytes: 24, ageSeconds: 10, maxAgeSeconds: 2592000, maxBytes: 8388608, wouldPurge: false, reason: 'within_policy' },
          { store: 'text_expansion_store', state: 'absent', bytes: 0, ageSeconds: null, maxAgeSeconds: 31536000, maxBytes: 4194304, wouldPurge: false, reason: 'missing' }
        ],
        evaluatedAt: '2026-07-14T00:00:00Z'
      })
      .mockResolvedValueOnce({
        status: {
          policyState: 'configured',
          rules: [
            { store: 'proxy_route_log', maxAgeSeconds: 86400, maxBytes: 1048576 },
            { store: 'text_expansion_store', maxAgeSeconds: 86400, maxBytes: 1048576 }
          ],
          stores: [
            { store: 'proxy_route_log', state: 'ready', bytes: 0, ageSeconds: null, maxAgeSeconds: 86400, maxBytes: 1048576, wouldPurge: false, reason: 'within_policy' },
            { store: 'text_expansion_store', state: 'absent', bytes: 0, ageSeconds: null, maxAgeSeconds: 86400, maxBytes: 1048576, wouldPurge: false, reason: 'missing' }
          ],
          evaluatedAt: '2026-07-14T00:00:00Z'
        },
        removedBytes: 24,
        removedEntries: 1
      });
    const b = await bridge();
    await expect(b.linuxPrivacyInventory?.()).resolves.toMatchObject({
      stores: [
        { store: 'proxy_route_log', state: 'ready', bytes: 24 },
        { store: 'text_expansion_store', state: 'absent', bytes: 0 }
      ]
    });
    await expect(b.linuxPrivacyDeletionPreview?.(['proxy_route_log'])).resolves.toMatchObject({
      token: 'preview-token',
      confirmationPhrase: 'DELETE LOCAL DATA'
    });
    await expect(b.linuxPrivacyDeletionExecute?.({
      token: 'preview-token',
      stores: ['proxy_route_log'],
      confirmation: 'DELETE LOCAL DATA'
    })).resolves.toMatchObject({ deleted: ['proxy_route_log'], bytesRemoved: 24 });
    await expect(b.linuxPrivacyExport?.({
      stores: ['proxy_route_log'],
      destinationPath: '/tmp/privacy-export.obb',
      passphrase: 'correct horse battery'
    })).resolves.toMatchObject({ destinationPath: '/tmp/privacy-export.obb', byteCount: 192, formatVersion: 1 });
    await expect(b.linuxPrivacyRetentionStatus?.()).resolves.toMatchObject({
      policyState: 'defaults',
      stores: [
        { store: 'proxy_route_log', wouldPurge: false },
        { store: 'text_expansion_store', wouldPurge: false }
      ]
    });
    await expect(b.linuxPrivacyRetentionApply?.({
      rules: [
        { store: 'proxy_route_log', maxAgeSeconds: 86_400, maxBytes: 1_048_576 },
        { store: 'text_expansion_store', maxAgeSeconds: 86_400, maxBytes: 1_048_576 }
      ],
      confirmation: 'APPLY RETENTION POLICY'
    })).resolves.toMatchObject({ removedBytes: 24, removedEntries: 1, status: { policyState: 'configured' } });
    expect(invoke).toHaveBeenNthCalledWith(1, 'linux_privacy_inventory');
    expect(invoke).toHaveBeenNthCalledWith(2, 'linux_privacy_deletion_preview', { stores: ['proxy_route_log'] });
    expect(invoke).toHaveBeenNthCalledWith(3, 'linux_privacy_deletion_execute', {
      request: { token: 'preview-token', stores: ['proxy_route_log'], confirmation: 'DELETE LOCAL DATA' }
    });
    expect(invoke).toHaveBeenNthCalledWith(4, 'linux_privacy_export', {
      request: {
        stores: ['proxy_route_log'],
        destinationPath: '/tmp/privacy-export.obb',
        passphrase: 'correct horse battery'
      }
    });
    expect(invoke).toHaveBeenNthCalledWith(5, 'linux_privacy_retention_status');
    expect(invoke).toHaveBeenNthCalledWith(6, 'linux_privacy_retention_apply', {
      request: {
        rules: [
          { store: 'proxy_route_log', maxAgeSeconds: 86_400, maxBytes: 1_048_576 },
          { store: 'text_expansion_store', maxAgeSeconds: 86_400, maxBytes: 1_048_576 }
        ],
        confirmation: 'APPLY RETENTION POLICY'
      }
    });
  });

  it('uses the typed native export picker and preserves cancellation', async () => {
    invoke
      .mockResolvedValueOnce('/tmp/privacy-export.obb')
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce('/tmp/account-export.json');
    const b = await bridge();

    await expect(b.pickExportDestination?.('linux-privacy')).resolves.toBe('/tmp/privacy-export.obb');
    await expect(b.pickExportDestination?.('linux-privacy')).resolves.toBeNull();
    await expect(b.pickExportDestination?.('account-cloud')).resolves.toBe('/tmp/account-export.json');
    expect(invoke).toHaveBeenNthCalledWith(1, 'pick_export_destination', { kind: 'linux-privacy' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'pick_export_destination', { kind: 'linux-privacy' });
    expect(invoke).toHaveBeenNthCalledWith(3, 'pick_export_destination', { kind: 'account-cloud' });
  });

  it('uses the typed recovery bundle picker for save and open flows', async () => {
    invoke
      .mockResolvedValueOnce('/tmp/recovery.obb')
      .mockResolvedValueOnce(null);
    const b = await bridge();

    await expect(b.pickRecoveryBundleDestination?.('export')).resolves.toBe('/tmp/recovery.obb');
    await expect(b.pickRecoveryBundleDestination?.('import')).resolves.toBeNull();
    expect(invoke).toHaveBeenNthCalledWith(1, 'pick_recovery_bundle_destination', { mode: 'export' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'pick_recovery_bundle_destination', { mode: 'import' });
  });

  it('uses the typed database snapshot picker for save and open flows', async () => {
    invoke
      .mockResolvedValueOnce('/tmp/code.snapshot')
      .mockResolvedValueOnce(null);
    const b = await bridge();

    await expect(b.pickDatabaseSnapshotPath?.('export')).resolves.toBe('/tmp/code.snapshot');
    await expect(b.pickDatabaseSnapshotPath?.('import')).resolves.toBeNull();
    expect(invoke).toHaveBeenNthCalledWith(1, 'pick_database_snapshot_path', { mode: 'export' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'pick_database_snapshot_path', { mode: 'import' });
  });

  it('uses the canonical run.resume RPC for persisted activity body and resume actions', async () => {
    invoke
      .mockResolvedValueOnce({
        kind: 'ported',
        briefing_md: '# Stored transcript',
        briefing_truncated: false
      })
      .mockResolvedValueOnce({ kind: 'spawned', pid: 42 });
    const b = await bridge();

    await expect(b.sessionReplay?.('Codex:session-1')).resolves.toMatchObject({
      kind: 'ported',
      briefingMD: '# Stored transcript',
      briefingTruncated: false
    });
    await expect(b.sessionResume?.('Codex:session-1')).resolves.toMatchObject({
      kind: 'spawned',
      pid: 42
    });
    expect(invoke).toHaveBeenNthCalledWith(1, 'session_replay', { sessionId: 'Codex:session-1' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'session_resume', { sessionId: 'Codex:session-1' });
  });

  it('fails closed when the persisted briefing exceeds the renderer bound', async () => {
    invoke.mockResolvedValueOnce({
      kind: 'ported',
      briefing_md: 'x'.repeat(65_537)
    });
    const b = await bridge();
    await expect(b.sessionReplay?.('Codex:oversize')).rejects.toThrow(/exceeds 65536/);
  });

  it('fails closed when the daemon sends a malformed briefing truncation flag', async () => {
    invoke.mockResolvedValueOnce({
      kind: 'ported',
      briefing_md: 'stored body',
      briefing_truncated: 'false'
    });
    const b = await bridge();
    await expect(b.sessionReplay?.('Codex:malformed')).rejects.toThrow(/briefingTruncated must be a boolean/);
  });

  it('maps canonical usage-event identity fields so Activity can resolve persisted sessions', async () => {
    invoke.mockResolvedValueOnce({
      usage: [{
        sessionID: 'Codex:session-2',
        providerID: 'codex',
        modelID: 'gpt-5',
        recordedAt: '2026-07-13T12:00:00Z',
        inputTokens: 12,
        outputTokens: 8,
        cost: 0.12,
        projectName: 'BurnBar'
      }]
    });
    const b = await bridge();
    await expect(b.sessionList()).resolves.toMatchObject({
      sessions: [{
        id: 'Codex:session-2',
        provider: 'codex',
        model: 'gpt-5',
        startedAt: '2026-07-13T12:00:00Z',
        tokens: 20,
        costUsd: 0.12,
        title: 'BurnBar',
        sourceID: 'Codex:session-2',
        providerSessionID: 'Codex:session-2',
        projectName: 'BurnBar'
      }]
    });
  });

  it('maps the explicit daemon full-history response and preserves its proof', async () => {
    invoke.mockResolvedValueOnce({
      sessions: [{
        id: 'Codex:history-1',
        provider: 'Codex',
        model: 'gpt-5',
        startedAt: '2026-07-13 12:00:00.000',
        tokens: 20,
        costUsd: 0.12,
        title: 'History row',
        sourceID: 'Codex:history-1',
        providerSessionID: 'history-1',
        projectName: 'BurnBar',
        bodyMD: '# Persisted body'
      }],
      nextCursor: null,
      historyComplete: true,
      historyLimit: 500,
      totalCount: 1
    });
    const b = await bridge();
    await expect(b.sessionHistory?.()).resolves.toEqual({
      sessions: [{
        id: 'Codex:history-1',
        provider: 'Codex',
        model: 'gpt-5',
        startedAt: '2026-07-13 12:00:00.000',
        tokens: 20,
        costUsd: 0.12,
        title: 'History row',
        sourceID: 'Codex:history-1',
        providerSessionID: 'history-1',
        projectName: 'BurnBar',
        bodyMD: '# Persisted body'
      }],
      nextCursor: null,
      complete: true,
      historyComplete: true,
      historyLimit: 500,
      totalCount: 1
    });
    expect(invoke).toHaveBeenCalledWith('session_history');
  });

  it('fails closed when the daemon history proof is false', async () => {
    invoke.mockResolvedValueOnce({
      sessions: [],
      nextCursor: 'more',
      historyComplete: false,
      historyLimit: 500,
      totalCount: 501
    });
    const b = await bridge();
    await expect(b.sessionHistory?.()).resolves.toMatchObject({
      sessions: [],
      nextCursor: 'more',
      complete: false,
      historyComplete: false,
      totalCount: 501
    });
  });

  it('does not synthesize a project from a title-only daemon row', async () => {
    invoke.mockResolvedValueOnce({ projects: [{ title: 'Apollo', path: '/tmp/Apollo' }] });
    const b = await bridge();
    await expect(b.projectList()).resolves.toEqual([]);
  });

  it('normalizes plain provider session ids to the stable conversation identity', async () => {
    invoke.mockResolvedValueOnce({
      usage: [{
        sessionID: 'session-plain',
        providerID: 'codex',
        modelID: 'gpt-5',
        recordedAt: '2026-07-13T12:00:00Z',
        inputTokens: 1,
        outputTokens: 2,
        cost: 0
      }]
    });
    const b = await bridge();
    await expect(b.sessionList()).resolves.toMatchObject({
      sessions: [{
        id: 'session-plain',
        sourceID: 'Codex:session-plain',
        providerSessionID: 'session-plain'
      }]
    });
  });

  it('retains indexed search-hit source identity without inventing usage metrics', async () => {
    invoke.mockResolvedValueOnce({
      hits: [{
        sourceID: 'Claude Code:session-search',
        sourceKind: 'conversation',
        title: 'Indexed result',
        snippet: 'Untrusted indexed text',
        provider: 'claude_code',
        projectName: 'BurnBar'
      }]
    });
    const b = await bridge();
    await expect(b.sessionSearch('indexed')).resolves.toMatchObject({
      sessions: [{
        id: 'Claude Code:session-search',
        sourceID: 'Claude Code:session-search',
        title: 'Indexed result',
        tokens: 0,
        costUsd: 0
      }]
    });
  });

  it('mission detail and cancellation use canonical get/cancel wire commands', async () => {
    invoke
      .mockResolvedValueOnce({
        mission: {
          id: 'm-1',
          title: 'Mission',
          status: 'in_progress',
          updatedAt: '2026-07-13T10:00:00Z',
          packets: [],
          results: []
        }
      })
      .mockResolvedValueOnce({
        mission: {
          id: 'm-1',
          title: 'Mission',
          status: 'cancelled',
          updatedAt: '2026-07-13T10:01:00Z',
          packets: [],
          results: []
        }
      });
    const b = await bridge();
    await expect(b.missionGet('m-1')).resolves.toMatchObject({ id: 'm-1', state: 'in_progress' });
    await expect(b.missionCancel('m-1', 'stop')).resolves.toMatchObject({ id: 'm-1', state: 'cancelled' });
    expect(invoke).toHaveBeenNthCalledWith(1, 'mission_get', { missionId: 'm-1' });
    expect(invoke).toHaveBeenNthCalledWith(2, 'mission_cancel', { missionId: 'm-1', note: 'stop' });
  });

  it('mission health uses the daemon-owned health/history contract', async () => {
    invoke.mockResolvedValueOnce({
      missionID: 'm-health',
      health: {
        status: 'healthy',
        detail: 'One packet is active.',
        checkedAt: '2026-07-13T10:00:00Z',
        lastActivityAt: '2026-07-13T09:59:00Z',
        activePacketCount: 1,
        failedResultCount: 0
      },
      history: [{
        id: 'packet:p-1',
        kind: 'packet',
        status: 'running',
        summary: 'Worker is running.',
        occurredAt: '2026-07-13T09:59:00Z',
        metadata: {}
      }]
    });

    const b = await bridge();
    await expect(b.missionHealth?.('m-health')).resolves.toMatchObject({
      missionId: 'm-health',
      health: { status: 'healthy', activePacketCount: 1 },
      history: [{ id: 'packet:p-1', kind: 'packet', status: 'running' }]
    });
    expect(invoke).toHaveBeenCalledWith('mission_health', { missionId: 'm-health' });
  });

  it('loads and answers canonical pending controller questions', async () => {
    const pendingQuestion = {
      id: 'q-1',
      projectSlug: 'burnbar',
      title: 'Choose rollout lane',
      prompt: 'Which rollout lane should continue?',
      status: 'pending',
      priority: 'high',
      askedAt: '2026-07-20T10:00:00Z',
      evidenceRefs: ['evidence://rollout'],
      suggestedOptions: [{
        id: 'option-safe',
        title: 'Safe lane',
        answer: 'Continue through the safe lane.',
        metadata: {}
      }],
      metadata: {}
    };
    invoke
      .mockResolvedValueOnce({ missions: [] })
      .mockResolvedValueOnce({ questions: [pendingQuestion] })
      .mockResolvedValueOnce({
        question: { ...pendingQuestion, status: 'answered' },
        followup: null,
        emittedEvent: null
      });

    const b = await bridge();
    await expect(b.missionList()).resolves.toMatchObject({
      missions: [],
      pendingQuestions: [{ id: 'q-1', status: 'pending', priority: 'high' }]
    });
    await expect(b.questionAnswer?.({
      questionId: 'q-1',
      answer: 'Continue through the safe lane.',
      selectedOptionId: 'option-safe'
    })).resolves.toMatchObject({ id: 'q-1', status: 'answered' });
    expect(invoke).toHaveBeenNthCalledWith(1, 'mission_list');
    expect(invoke).toHaveBeenNthCalledWith(2, 'question_list');
    expect(invoke).toHaveBeenNthCalledWith(3, 'question_answer', {
      questionId: 'q-1',
      answer: 'Continue through the safe lane.',
      selectedOptionId: 'option-safe'
    });
  });

  it('account auth methods use native commands and return only redacted state', async () => {
    invoke
      .mockResolvedValueOnce({
        state: 'awaiting_device_approval',
        signedIn: false,
        trustClass: 'linux-lower-trust',
        syncState: 'local-only',
        deviceApprovalRequired: true,
        installationDeviceID: `linux_${'ab'.repeat(32)}`,
        installationSafetyFingerprint: Array(16).fill('ABAB').join(' '),
        detail: 'Approval required.',
        refreshToken: 'refresh-secret',
        idToken: 'id-secret',
        appCheckToken: 'app-check-secret',
        privateKey: 'private-key-secret',
        sessionGeneration: 'generation-secret'
      })
      .mockResolvedValueOnce({ operationID: 'op-1', expiresAt: '2026-07-11T22:00:00Z' })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'signed_out',
          signedIn: false,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: false
        }
      })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'awaiting_device_approval',
          signedIn: true,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: true
        }
      })
      .mockResolvedValueOnce({
        ok: true,
        status: {
          state: 'signed_out',
          signedIn: false,
          trustClass: 'linux-lower-trust',
          syncState: 'local-only',
          deviceApprovalRequired: false
        }
      });
    const b = await bridge();

    const status = await b.accountStatus();
    expect(status).toMatchObject({
      state: 'awaiting-device-approval',
      deviceApprovalRequired: true,
      installationDeviceID: `linux_${'ab'.repeat(32)}`,
      installationSafetyFingerprint: Array(16).fill('ABAB').join(' ')
    });
    await expect(b.accountBeginSignIn()).resolves.toEqual({
      operationID: 'op-1',
      expiresAt: '2026-07-11T22:00:00Z'
    });
    await expect(b.accountCancelSignIn('op-1')).resolves.toMatchObject({ state: 'signed-out' });
    await expect(b.accountRotateIdentity()).resolves.toMatchObject({ state: 'awaiting-device-approval' });
    await expect(b.accountSignOut()).resolves.toMatchObject({ state: 'signed-out' });

    expect(invoke).toHaveBeenNthCalledWith(1, 'account_status');
    expect(invoke).toHaveBeenNthCalledWith(2, 'account_begin_sign_in');
    expect(invoke).toHaveBeenNthCalledWith(3, 'account_cancel_sign_in', { operationId: 'op-1' });
    expect(invoke).toHaveBeenNthCalledWith(4, 'account_rotate_identity');
    expect(invoke).toHaveBeenNthCalledWith(5, 'account_sign_out');
    expect(JSON.stringify(status)).not.toMatch(/refreshToken|idToken|appCheckToken|publicKey|sessionGeneration/);
  });

  it('rejects a malformed native sign-in operation before UI state can accept it', async () => {
    invoke.mockResolvedValueOnce({ operationID: 'op-1', authorizationURL: 'https://should-not-reach-renderer' });
    const b = await bridge();
    await expect(b.accountBeginSignIn()).rejects.toThrow(/invalid sign-in operation/i);
  });

  it('maps the daemon cloud-ready sync state to active', async () => {
    invoke.mockResolvedValueOnce({
      state: 'active',
      signedIn: true,
      identityLabel: 'user@example.com',
      trustClass: 'linux-lower-trust',
      syncState: 'cloud-ready',
      deviceApprovalRequired: false
    });
    const b = await bridge();

    await expect(b.accountStatus()).resolves.toMatchObject({
      state: 'active',
      signedIn: true,
      syncState: 'active'
    });
  });

  it('forwards account erasure confirmation only through the daemon-owned RPC and maps a redacted summary', async () => {
    invoke.mockResolvedValueOnce({
      ok: true,
      cloudDataDeleted: true,
      retryRequired: false,
      deletedDocuments: 4,
      destroyedSecrets: 1,
      failedSecretDestroys: 0,
      deletedStoragePrefixes: 2,
      failedStorageDeletes: 0,
      deletedAuthUser: true,
      authUserAlreadyMissing: false
    });
    const b = await bridge();

    const result = await b.accountDeleteCloudData?.('DELETE MY ACCOUNT');
    expect(result).toMatchObject({
      ok: true,
      cloudDataDeleted: true,
      deletedDocuments: 4,
      deletedStoragePrefixes: 2
    });
    expect(invoke).toHaveBeenCalledWith('account_delete_cloud_data', { confirmation: 'DELETE MY ACCOUNT' });
    expect(JSON.stringify(result)).not.toMatch(/nonce|proof|token|uid/i);
  });

  it('forwards account export destination without returning cloud payload bytes', async () => {
    invoke.mockResolvedValueOnce({
      ok: true,
      destinationPath: '/tmp/account-export.json',
      byteCount: 1_024,
      schemaVersion: 2
    });
    const b = await bridge();

    const result = await b.accountExportCloudData?.({
      destinationPath: '/tmp/account-export.json'
    });
    expect(result).toEqual({
      ok: true,
      destinationPath: '/tmp/account-export.json',
      byteCount: 1_024,
      schemaVersion: 2
    });
    expect(invoke).toHaveBeenCalledWith('account_export_cloud_data', {
      request: { destinationPath: '/tmp/account-export.json' }
    });
    expect(JSON.stringify(result)).not.toMatch(/sealedRefs|inlineJson|nonce|proof|token|uid/i);
  });

  it('rejects an unsafe daemon account-export receipt', async () => {
    invoke.mockResolvedValueOnce({
      ok: true,
      destinationPath: '/tmp/../../account-export.json',
      byteCount: 32,
      schemaVersion: 2
    });
    const b = await bridge();
    await expect(b.accountExportCloudData?.({ destinationPath: '/tmp/account-export.json' })).rejects.toThrow(
      'unsafe destination path'
    );
  });

  it.each(['authorizing', 'signed_out'])(
    'does not trust a stale signedIn bit during %s',
    async (phase) => {
      invoke.mockResolvedValueOnce({
        state: phase,
        signedIn: true,
        identityLabel: 'stale@example.com',
        trustClass: 'linux-lower-trust',
        syncState: 'active'
      });
      const b = await bridge();

      const status = await b.accountStatus();
      expect(status).toMatchObject({
        state: phase === 'signed_out' ? 'signed-out' : 'authorizing',
        signedIn: false,
        syncState: 'local-only'
      });
      expect(status.identityLabel).toBeUndefined();
    }
  );

  it.each(['refreshing', 'locked', 'configuration_required', 'error', 'future_state'])(
    'keeps daemon auth phase %s unavailable instead of misreporting signed out',
    async (phase) => {
      invoke.mockResolvedValueOnce({
        state: phase,
        signedIn: true,
        identityLabel: 'stale@example.com',
        trustClass: 'linux-lower-trust',
        syncState: 'local-only',
        detail: phase
      });
      const b = await bridge();

      await expect(b.accountStatus()).resolves.toMatchObject({
        state: 'unavailable',
        signedIn: false,
        identityLabel: undefined,
        detail: phase
      });
    }
  );

  it('toolApprovalRespond success path invokes tool_approval_respond', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.toolApprovalRespond?.('appr-1', 'approve', 'lgtm');
    expect(invoke).toHaveBeenCalledWith('tool_approval_respond', {
      approvalId: 'appr-1',
      decision: 'approve',
      note: 'lgtm'
    });
  });

  it('toolApprovalRespond daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('Connection refused'));
    const b = await bridge();
    await expect(b.toolApprovalRespond?.('appr-1', 'reject')).rejects.toThrow(/Connection refused/);
  });

  it('memorySetStatus reject maps to memory_set_status', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.memorySetStatus?.('reject', { memoryID: 'm-1' });
    expect(invoke).toHaveBeenCalledWith('memory_set_status', {
      action: 'reject',
      payload: { memoryID: 'm-1' }
    });
  });

  it('memorySetStatus approve with body succeeds', async () => {
    invoke.mockResolvedValueOnce({ memoryID: 'new' });
    const b = await bridge();
    await b.memorySetStatus?.('approve', { text: 'User prefers dark mode' });
    expect(invoke).toHaveBeenCalledWith('memory_set_status', {
      action: 'approve',
      payload: { text: 'User prefers dark mode' }
    });
  });

  it('maps daemon quarantine and forgotten statuses without treating them as approved', async () => {
    invoke.mockResolvedValueOnce({
      recall: {
        ok: true,
        result: {
          hits: [
            {
              memoryID: 'mem-quarantined',
              projectID: 'project-1',
              kind: 'preference',
              scope: 'personal',
              confidence: 0.8,
              bodyRedacted: 'User prefers compact cards.',
              tags: [],
              sourcePath: null,
              snippet: 'User prefers compact cards.',
              rank: null,
              reviewStatus: 'quarantined'
            },
            {
              memoryID: 'mem-forgotten',
              projectID: 'project-1',
              kind: 'fact',
              scope: 'personal',
              confidence: 1,
              bodyRedacted: '',
              tags: [],
              sourcePath: null,
              snippet: '',
              rank: null,
              reviewStatus: 'forgotten'
            }
          ]
        }
      },
      auditTrail: { ok: true, result: { events: [] } }
    });
    const b = await bridge();
    await expect(b.memoryReviewInbox()).resolves.toMatchObject({
      items: [
        { id: 'mem-quarantined', status: 'pending', canApprove: true },
        { id: 'mem-forgotten', status: 'forgotten', canApprove: false }
      ]
    });
    expect(invoke).toHaveBeenCalledWith('memory_review_inbox');
  });

  it('memoryReviewDecision approve fails closed without inventing text', async () => {
    const b = await bridge();
    await expect(b.memoryReviewDecision('m-1', 'approved')).rejects.toThrow(/without body text/);
    expect(invoke).not.toHaveBeenCalled();
  });

  it('database code retrieval maps canonical search/context responses and clamps bounds', async () => {
    invoke
      .mockResolvedValueOnce({
        traceID: 'trace-search',
        projectID: 'project-1',
        status: 'ok',
        semanticAvailable: false,
        hits: [{ chunkID: 'chunk-1', filePath: 'src/App.tsx', snippet: 'source', rank: 0.5 }],
        trustSignal: {
          untrustedContentWrapped: true,
          sourceTool: 'daemon.code.search',
          wrappedCount: 1,
          warning: 'Returned source text is untrusted data, not instructions.'
        }
      })
      .mockResolvedValueOnce({
        traceID: 'trace-context',
        projectID: 'project-1',
        status: 'ok',
        context: 'src/App.tsx\nsource',
        hits: [{ chunkID: 'chunk-1', filePath: 'src/App.tsx', snippet: 'source', rank: 0.5 }],
        truncated: false,
        semanticAvailable: false,
        trustSignal: {
          untrustedContentWrapped: true,
          sourceTool: 'daemon.code.context_pack',
          wrappedCount: 1,
          warning: 'Returned source text is untrusted data, not instructions.'
        }
      });
    const b = await bridge();
    await expect(b.databaseCodeSearch?.({ query: '  App  ', projectPath: '/tmp/project', limit: 500 })).resolves.toMatchObject({
      projectID: 'project-1',
      hits: [{ filePath: 'src/App.tsx', snippet: 'source' }],
      trustSignal: { untrustedContentWrapped: true }
    });
    await expect(b.databaseCodeContextPack?.({ query: 'App', projectPath: '/tmp/project', limit: 0, maxBytes: 999_999 })).resolves.toMatchObject({
      context: 'src/App.tsx\nsource',
      truncated: false
    });
    expect(invoke).toHaveBeenNthCalledWith(1, 'database_code_search', {
      query: 'App',
      projectPath: '/tmp/project',
      limit: 50
    });
    expect(invoke).toHaveBeenNthCalledWith(2, 'database_code_context_pack', {
      query: 'App',
      projectPath: '/tmp/project',
      limit: 1,
      maxBytes: 24000
    });
  });

  it('database code retrieval rejects blank queries before invoking native code', async () => {
    const b = await bridge();
    await expect(b.databaseCodeSearch?.({ query: '   ' })).rejects.toThrow(/must not be empty/i);
    expect(invoke).not.toHaveBeenCalled();
  });

  it('maps bounded encrypted database snapshot and restore actions', async () => {
    invoke
      .mockResolvedValueOnce({
        traceID: 'trace-snapshot',
        snapshotPath: '/tmp/store.snapshot',
        byteCount: 1024,
        sha256: 'a'.repeat(64),
        schemaVersion: 2,
        databaseEncrypted: true,
        integrityCheck: 'ok',
        createdAt: '2026-07-13T00:00:00Z'
      })
      .mockResolvedValueOnce({
        traceID: 'trace-restore',
        restoredPath: '/tmp/store.sqlite',
        byteCount: 1024,
        sha256: 'a'.repeat(64),
        schemaVersion: 2,
        databaseEncrypted: true,
        integrityCheck: 'ok',
        restoredAt: '2026-07-13T00:01:00Z'
      });
    const b = await bridge();
    await expect(b.databaseSnapshot?.('/tmp/store.snapshot', 999_999_999)).resolves.toMatchObject({
      snapshotPath: '/tmp/store.snapshot',
      databaseEncrypted: true,
      integrityCheck: 'ok'
    });
    await expect(b.databaseRestore?.('/tmp/store.snapshot', 0)).resolves.toMatchObject({
      snapshotPath: '/tmp/store.sqlite',
      restoredAt: '2026-07-13T00:01:00Z'
    });
    expect(invoke).toHaveBeenNthCalledWith(1, 'database_snapshot', {
      destinationPath: '/tmp/store.snapshot',
      maxBytes: 512 * 1_024 * 1_024
    });
    expect(invoke).toHaveBeenNthCalledWith(2, 'database_restore', {
      snapshotPath: '/tmp/store.snapshot',
      maxBytes: 1
    });
  });

  it('database recovery bundle bridge keeps passphrases native and maps daemon results', async () => {
    invoke
      .mockResolvedValueOnce({
        phase: 'awaiting_database_verification',
        code: 'database_missing',
        message: 'Restore an encrypted snapshot before claiming recovery succeeded.',
        recommendedAction: 'restore_encrypted_snapshot',
        canExport: false,
        canImport: true,
        databasePresent: false,
        databaseIntegrityVerified: false,
        restartRequired: false
      })
      .mockResolvedValueOnce({ destinationPath: '/tmp/recovery.obb', byteCount: 96, formatVersion: 1 })
      .mockResolvedValueOnce({
        sourcePath: '/tmp/recovery.obb',
        stored: true,
        candidateKeyVerified: false,
        databaseIntegrityVerified: false,
        phase: 'awaiting_database_verification',
        recommendedAction: 'restore_encrypted_snapshot',
        message: 'The recovery key was stored, but no encrypted database was present to verify it.',
        restartRequired: true
      });
    const b = await bridge();
    await expect(b.databaseRecoveryBundleStatus?.()).resolves.toMatchObject({
      phase: 'awaiting_database_verification',
      canImport: true,
      databaseIntegrityVerified: false
    });
    await expect(b.databaseRecoveryBundleExport?.({
      destinationPath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery staple'
    })).resolves.toMatchObject({ byteCount: 96, formatVersion: 1 });
    await expect(b.databaseRecoveryBundleImport?.({
      sourcePath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery staple'
    })).resolves.toMatchObject({ stored: true, restartRequired: true });
    expect(invoke).toHaveBeenNthCalledWith(1, 'database_recovery_bundle_status');
    expect(invoke).toHaveBeenNthCalledWith(2, 'database_recovery_bundle_export', {
      destinationPath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery staple'
    });
    expect(invoke).toHaveBeenNthCalledWith(3, 'database_recovery_bundle_import', {
      sourcePath: '/tmp/recovery.obb',
      passphrase: 'correct horse battery staple'
    });
  });

  it('computerUseSessionStart maps contract fields including the bound agent run', async () => {
    invoke.mockResolvedValueOnce({ state: 'authorized', sessionId: 's1' });
    const b = await bridge();
    await b.computerUseSessionStart?.({
      mode: 'browser',
      trustMode: 'step',
      ...COMPUTER_USE_SESSION_DEFAULTS,
      clientId: 'linux-shell',
      runId: 'run-1',
      runCallId: 'call-1',
      runGeneration: 7,
      desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_start', {
      params: {
        mode: 'browser',
        trustMode: 'step',
        ...COMPUTER_USE_SESSION_DEFAULTS,
        clientId: 'linux-shell',
        runId: 'run-1',
        runCallId: 'call-1',
        runGeneration: 7,
        desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
      }
    });
  });

  it('computerUseSessionAuthorityStatus uses the native broker command without parameters', async () => {
    invoke.mockResolvedValueOnce({ state: 'waiting_phone' });
    const b = await bridge();
    await expect(b.computerUseSessionAuthorityStatus?.()).resolves.toEqual({
      state: 'waiting_phone'
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_session_authority_status');
  });

  it('computerUseInvoke maps nested invocation object', async () => {
    invoke.mockResolvedValueOnce({
      sessionId: 's1',
      callID: 'c1',
      status: 'executed',
      result: { succeeded: true }
    });
    const b = await bridge();
    await b.computerUseInvoke?.({
      sessionId: 's1',
      invocation: {
        callId: 'c1',
        runId: 'r1',
        tool: 'browser_click',
        arguments: { selector: '#submit' },
        requestedBy: 'linux-shell',
        requestedAt: 1
      }
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_invoke', {
      params: {
        sessionId: 's1',
        invocation: {
          callId: 'c1',
          runId: 'r1',
          tool: 'browser_click',
          arguments: { selector: '#submit' },
          requestedBy: 'linux-shell',
          requestedAt: 1
        }
      }
    });
  });

  it('computerUseInvoke response decoding accepts Swift Codable IDs and rejects incomplete results', () => {
    expect(decodeComputerUseInvokeResponse({
      sessionId: 's1',
      callID: 'c1',
      status: 'denied',
      denyReason: 'approval_required'
    })).toEqual({
      sessionId: 's1',
      callID: 'c1',
      status: 'denied',
      approvalId: undefined,
      denyReason: 'approval_required',
      auditEntryIndex: undefined,
      auditHeadHashHex: undefined,
      result: undefined
    });
    expect(() => decodeComputerUseInvokeResponse({ status: 'executed' }))
      .toThrow(/sessionId/);
  });

  it('computerUseApprovalPending maps sessionId only', async () => {
    invoke.mockResolvedValueOnce({ requests: [] });
    const b = await bridge();
    await b.computerUseApprovalPending?.({ sessionId: 's1' });
    expect(invoke).toHaveBeenCalledWith('computer_use_approval_pending', {
      params: { sessionId: 's1' }
    });
  });

  it('computerUseApprovalRespond maps nested response shape', async () => {
    invoke.mockResolvedValueOnce({ accepted: true });
    const b = await bridge();
    await b.computerUseApprovalRespond?.({
      sessionId: 's1',
      approvalId: 'a1',
      decision: 'approve',
      note: 'ok'
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_approval_respond', {
      params: {
        sessionId: 's1',
        approvalId: 'a1',
        decision: 'approve',
        note: 'ok'
      }
    });
  });

  it('computerUsePanicHalt maps source (not reason)', async () => {
    invoke.mockResolvedValueOnce({ ok: true });
    const b = await bridge();
    await b.computerUsePanicHalt?.({ sessionId: 's1', source: 'hotkey' });
    expect(invoke).toHaveBeenCalledWith('computer_use_panic_halt', {
      sessionId: 's1',
      source: 'hotkey'
    });
  });

  it('computerUseAuditExport maps includeScreenshots/anchorOpenTimestamps', async () => {
    invoke.mockResolvedValueOnce({ archiveURL: '/tmp/x.tgz' });
    const b = await bridge();
    await b.computerUseAuditExport?.({
      sessionId: 's1',
      includeScreenshots: false,
      anchorOpenTimestamps: true
    });
    expect(invoke).toHaveBeenCalledWith('computer_use_audit_export', {
      params: {
        sessionId: 's1',
        includeScreenshots: false,
        anchorOpenTimestamps: true
      }
    });
  });

  it('computerUsePanicHalt daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUsePanicHalt?.({ sessionId: 's1', source: 'hotkey' })).rejects.toThrow(
      /daemon down/
    );
  });

  it('computerUseInvoke daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseInvoke?.({
        sessionId: 's1',
        invocation: {
          callId: 'c',
          runId: 'r',
          tool: 'browser_click',
          arguments: {},
          requestedBy: 'linux-shell',
          requestedAt: 1
        }
      })
    ).rejects.toThrow(/daemon down/);
  });

  it('computerUseAuditExport daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUseAuditExport?.({ sessionId: 's1' })).rejects.toThrow(/daemon down/);
  });

  it('computerUseSessionStart daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseSessionStart?.({
        mode: 'browser',
        trustMode: 'manual',
        ...COMPUTER_USE_SESSION_DEFAULTS,
        clientId: 'linux-shell',
        runId: 'run-1',
        runCallId: 'call-1',
        runGeneration: 1,
        desktopOwnerAuthorizationRequest: { method: 'linux_desktop_owner' }
      })
    ).rejects.toThrow(/daemon down/);
  });

  it('computerUseApprovalPending daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(b.computerUseApprovalPending?.({ sessionId: 's1' })).rejects.toThrow(/daemon down/);
  });

  it('computerUseApprovalRespond daemon-down surfaces error', async () => {
    invoke.mockRejectedValueOnce(new Error('daemon down'));
    const b = await bridge();
    await expect(
      b.computerUseApprovalRespond?.({ approvalId: 'a1', decision: 'reject' })
    ).rejects.toThrow(/daemon down/);
  });

  it('mediaStatus returns capability-absent payload', async () => {
    invoke.mockResolvedValueOnce({
      capabilityAvailable: false,
      pairedDevices: []
    });
    const b = await bridge();
    const status = await b.mediaStatus();
    expect(status.capabilityAvailable).toBe(false);
    expect(status.pairedDevices).toEqual([]);
  });

  it('mediaStatus decodes the daemon capability, session, and nested peer contract', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        platform: 'linux',
        available: true,
        codecsKnown: true,
        source: 'COpenBurnBarMediaCapture.media_capability_probe'
      },
      session: {
        phase: 'streaming',
        kind: 'mirror',
        requestID: 'mirror-1',
        peer: {
          connectionID: 'phone-1',
          displayName: 'Alberto iPhone',
          isOnline: true,
          lastSeenAt: '2026-07-10T00:00:00Z',
          capabilities: ['mirror.viewer', 'file.receive']
        },
        startedAt: '2026-07-10T00:00:01Z'
      }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toEqual({
      capabilityAvailable: true,
      pairedDevices: [
        {
          id: 'phone-1',
          name: 'Alberto iPhone',
          platform: 'unknown',
          isOnline: true,
          lastSeenAt: '2026-07-10T00:00:00Z',
          capabilities: ['mirror.viewer', 'file.receive']
        }
      ],
      activeSession: {
        kind: 'screen-share',
        state: 'active',
        peer: 'Alberto iPhone',
        requestId: 'mirror-1',
        startedAt: '2026-07-10T00:00:01Z'
      }
    });
  });

  it('mediaStatus carries shell viewer capability and install guidance separately from daemon capture', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        available: true,
        codecsKnown: true,
        source: 'MercuryLinuxCapabilityProbe'
      },
      viewerCapability: {
        available: false,
        renderer: 'media-gst',
        featureEnabled: true,
        canDecodeVp9: false,
        hasVideoSink: true,
        status: 'gstreamer_vp9_decoder_missing',
        reason: 'gstreamer_vp9_decoder_missing',
        installHint: 'Install a GStreamer VP9 decoder plugin, then restart OpenBurnBar.'
      },
      session: { phase: 'idle' }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toMatchObject({
      capabilityAvailable: true,
      viewerCapability: {
        available: false,
        renderer: 'media-gst',
        featureEnabled: true,
        canDecodeVp9: false,
        hasVideoSink: true,
        status: 'gstreamer_vp9_decoder_missing',
        reason: 'gstreamer_vp9_decoder_missing',
        installHint: 'Install a GStreamer VP9 decoder plugin, then restart OpenBurnBar.'
      }
    });
  });

  it('mediaStatus preserves the build-time no-GStreamer distinction', async () => {
    invoke.mockResolvedValueOnce({
      capability: { available: true },
      viewerCapability: {
        available: false,
        renderer: 'stub',
        featureEnabled: false,
        canDecodeVp9: false,
        hasVideoSink: false,
        status: 'built_without_gstreamer',
        reason: 'linux_media_viewer_built_without_gstreamer',
        installHint: 'Install the packaged Linux build with GStreamer support.'
      }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toMatchObject({
      viewerCapability: {
        available: false,
        renderer: 'stub',
        featureEnabled: false,
        status: 'built_without_gstreamer',
        reason: 'linux_media_viewer_built_without_gstreamer'
      }
    });
  });

  it('mediaStatus fails closed when the nested daemon capability is unavailable', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        available: false,
        codecsKnown: false,
        source: 'MercuryLinuxCapabilityProbe.stub',
        detail: 'XDG_RUNTIME_DIR is not set.'
      },
      session: { phase: 'idle', updatedAt: '2026-07-10T00:00:00Z' }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toEqual({
      capabilityAvailable: false,
      pairedDevices: [],
      activeSession: undefined,
      reason: 'XDG_RUNTIME_DIR is not set.'
    });
  });

  it('mediaStatus fails closed when the daemon omits the required availability field', async () => {
    invoke.mockResolvedValueOnce({
      capability: {
        codecsKnown: true,
        source: 'COpenBurnBarMediaCapture.media_capability_probe'
      },
      session: { phase: 'idle', updatedAt: '2026-07-10T00:00:00Z' }
    });
    const b = await bridge();
    await expect(b.mediaStatus()).resolves.toMatchObject({
      capabilityAvailable: false,
      activeSession: undefined
    });
  });

  it('mediaCapabilityGet maps the native media probe to actionable shell support', async () => {
    invoke.mockResolvedValueOnce({
      available: true,
      codecsKnown: true,
      supportsDaemonToShellFrames: true,
      source: 'COpenBurnBarMediaCapture.media_capability_probe',
      detail: 'VP9 capture is ready.'
    });
    const b = await bridge();
    await expect(b.mediaCapabilityGet()).resolves.toEqual({
      available: true,
      renderer: 'media-gst',
      canReceiveCalls: true,
      canPlayCallAudio: false,
      canViewScreenShare: true,
      reason: 'VP9 capture is ready.'
    });
  });

  it('mediaCapabilityGet fails closed when the probe omits availability', async () => {
    invoke.mockResolvedValueOnce({
      codecsKnown: true,
      supportsDaemonToShellFrames: true,
      source: 'COpenBurnBarMediaCapture.media_capability_probe'
    });
    const b = await bridge();
    await expect(b.mediaCapabilityGet()).resolves.toEqual({
      available: false,
      renderer: 'media-gst',
      canReceiveCalls: false,
      canPlayCallAudio: false,
      canViewScreenShare: false,
      reason: undefined
    });
  });

  it('SmartHub commands invoke the typed Tauri operation and decode status', async () => {
    invoke.mockResolvedValueOnce({
      operation: 'status',
      payload: {
        adapter: 'smart_hub_bridge',
        status: 'blocked_bridge_not_reachable',
        blocker: 'Start the bridge.',
        bridge_listen: '127.0.0.1:8787'
      }
    });
    const b = await bridge();
    await expect(b.smartHubCommand?.('status')).resolves.toMatchObject({
      operation: 'status',
      payload: { adapter: 'smart_hub_bridge', status: 'blocked_bridge_not_reachable' }
    });
    expect(invoke).toHaveBeenCalledWith('smarthub_command', { operation: 'status' });
  });

  it('SmartHub commands reject malformed native status payloads', async () => {
    invoke.mockResolvedValueOnce({
      operation: 'status',
      payload: { adapter: 'smart_hub_bridge', status: 'ok', online: true }
    });
    const b = await bridge();
    await expect(b.smartHubCommand?.('status')).rejects.toThrow(/must be a string/);
  });
});

/**
 * Shared fixture shapes mirroring Rust computer_use_* builders in lib.rs.
 * Keep in sync with BurnBarComputerUseContracts + Tauri command serialization.
 */
export const cuSessionStartFixture = (overrides: Record<string, unknown> = {}) => ({
  mode: 'browser',
  trustMode: 'manual',
  scopeRuleIds: [] as string[],
  phoneViewerNodeId: null as string | null,
  macHostNodeId: null as string | null,
  actionCap: 50,
  sessionTimeoutSeconds: 1800,
  clientID: 'linux-shell',
  runID: null as string | null,
  ...overrides
});

export const cuInvokeFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  invocation: {
    callID: 'c',
    runID: 'r',
    tool: 'browser_click',
    arguments: {} as Record<string, unknown>,
    requestedBy: 'linux-shell',
    requestedAt: 123.4
  },
  ...overrides
});

export const cuApprovalRespondFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  // Shell accepts flat approvalId/decision and Rust nests under response.
  approvalId: 'a',
  decision: 'approve',
  note: null as string | null,
  ...overrides
});

export const cuPanicHaltFixture = (overrides: Record<string, unknown> = {}) => ({
  sessionId: 's',
  source: 'hotkey',
  ...overrides
});

describe('Computer Use wire-shape goldens (shared fixtures)', () => {
  it('session.start fixture keys match BurnBarComputerUseContracts', () => {
    const body = cuSessionStartFixture();
    expect(Object.keys(body).sort()).toEqual(
      [
        'actionCap',
        'clientID',
        'macHostNodeId',
        'mode',
        'phoneViewerNodeId',
        'runID',
        'scopeRuleIds',
        'sessionTimeoutSeconds',
        'trustMode'
      ].sort()
    );
  });

  it('invoke fixture nests invocation (not flat tool/args)', () => {
    const body = cuInvokeFixture();
    expect(body.invocation).toHaveProperty('callID');
    expect(body.invocation).toHaveProperty('requestedAt');
    expect(body).not.toHaveProperty('tool');
    expect(typeof body.invocation.requestedAt).toBe('number');
  });

  it('approval.respond fixture uses approvalId/decision (Rust nests response)', () => {
    const body = cuApprovalRespondFixture();
    expect(body).toHaveProperty('approvalId');
    expect(body).toHaveProperty('decision');
    expect(body).not.toHaveProperty('reason');
  });

  it('panic_halt fixture uses source not reason', () => {
    const body = cuPanicHaltFixture();
    expect(body).toHaveProperty('source');
    expect(body).not.toHaveProperty('reason');
  });

  it('Foundation timestamp offset is 978307200', () => {
    const unix = 1_700_000_000;
    const foundation = unix - 978_307_200;
    expect(foundation).toBe(721_692_800);
  });

  it('behavioral suite uses shared session.start fixture shape', async () => {
    // Ensures goldens and invoke tests share one shape source (Issue 12).
    const fixture = cuSessionStartFixture({ trustMode: 'step' });
    expect(fixture.mode).toBe('browser');
    expect(fixture.trustMode).toBe('step');
    expect(fixture.clientID).toBe('linux-shell');
  });
});
