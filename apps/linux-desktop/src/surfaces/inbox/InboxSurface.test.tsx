// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useInboxStore } from '../../state/inboxStore.js';
import { useShellStore } from '../../state/shellStore.js';
import type { AIInboxPresentationRow } from '../../tauriBridge.js';
import type { AIInboxAction } from '../../tauriBridge.js';
import {
  activityConversationRouteHash,
  projectWorkspaceRouteHash
} from '../../routes.js';
import { inboxListSections, InboxSurface } from './InboxSurface.js';

function presentationRow({
  id,
  title,
  priority,
  lastSeenAt
}: {
  id: string;
  title: string;
  priority: 1 | 2 | 3 | 4;
  lastSeenAt: string;
}): AIInboxPresentationRow {
  return {
    item: {
      summary: {
        id,
        fingerprint: `fixture:${id}`,
        kind: 'brief',
        priority,
        state: 'new',
        title,
        occurrenceCount: 1,
        firstSeenAt: lastSeenAt,
        lastSeenAt,
        modelProvenance: 'fixture',
        hasMemoryCandidates: false
      },
      summaryMarkdown: title,
      tickID: 'fixture-tick',
      payload: {
        version: 1,
        evidence: [],
        memoryCandidates: [],
        actions: [],
        metrics: {}
      }
    },
    presentation: {}
  };
}

function resetStores(): void {
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: true,
    route: 'inbox',
    routeHash: '#/inbox',
    routeRevision: 0
  });
  useInboxStore.setState({
    rows: [],
    openCount: 0,
    activeUnreadCount: 0,
    selectedID: null,
    threads: {},
    plans: [],
    runs: [],
    filter: 'active',
    loading: false,
    detailLoading: false,
    plansLoading: false,
    error: null,
    actionError: null,
    refusalReason: null,
    busy: {}
  });
  location.hash = '#/inbox';
}

function replaceFixtureActions(actions: AIInboxAction[]): void {
  useInboxStore.setState((state) => ({
    rows: state.rows.map((row, index) => index === 0
      ? {
          ...row,
          item: {
            ...row.item,
            payload: {
              ...row.item.payload,
              actions
            }
          }
        }
      : row)
  }));
}

describe('InboxSurface', () => {
  beforeEach(resetStores);
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('renders the macOS-shaped Inbox detail and durable disposition controls', async () => {
    render(<InboxSurface />);

    expect(await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' })).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Needs attention' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Useful' }).getAttribute('aria-pressed')).toBe('false');
    expect(screen.getByRole('button', { name: 'Not useful' }).getAttribute('aria-pressed')).toBe('false');
    expect(await screen.findByRole('button', { name: 'Mark unread' })).toBeTruthy();
    expect(screen.getByRole('combobox', { name: 'Snooze inbox item' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Archive' })).toBeTruthy();
  });

  it('persists feedback, snooze, archive, and unarchive in fixture-mode semantics', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });
    await screen.findByRole('button', { name: 'Mark unread' });

    fireEvent.click(screen.getByRole('button', { name: 'Useful' }));
    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Useful' }).getAttribute('aria-pressed')).toBe('true');
    });

    fireEvent.change(screen.getByRole('combobox', { name: 'Snooze inbox item' }), {
      target: { value: '3600' }
    });
    expect(await screen.findByRole('button', { name: 'Clear snooze' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Archive' }));
    expect(await screen.findByRole('button', { name: 'Unarchive' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Unarchive' }));
    expect(await screen.findByRole('button', { name: 'Archive' })).toBeTruthy();
  });

  it('routes memory and plan actions through the daemon-authoritative store actions', async () => {
    const approveMemoryCandidate = vi.fn(async () => true);
    const createFollowup = vi.fn(async () => true);
    const rememberPlanStep = vi.fn(async () => true);
    useInboxStore.setState({
      approveMemoryCandidate,
      createFollowup,
      rememberStep: rememberPlanStep
    });
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });

    const rememberCandidate = screen.getByRole('button', { name: 'Remember this' });
    expect(rememberCandidate.hasAttribute('disabled')).toBe(false);
    fireEvent.click(rememberCandidate);
    expect(await screen.findByRole('button', { name: 'Saved to memory' })).toBeTruthy();
    expect(approveMemoryCandidate).toHaveBeenCalledWith(
      'fixture-inbox-1',
      'fixture:stuck-pr:2172',
      'fixture-memory-1'
    );

    const followUp = screen.getByRole('button', { name: 'Follow up' });
    expect(followUp.hasAttribute('disabled')).toBe(false);
    fireEvent.click(followUp);
    expect(createFollowup).toHaveBeenCalledWith('fixture-step-1');

    const rememberStepButton = screen.getByRole('button', { name: 'Remember' });
    expect(rememberStepButton.hasAttribute('disabled')).toBe(false);
    fireEvent.click(rememberStepButton);
    expect(rememberPlanStep).toHaveBeenCalledWith('fixture-step-1');
  });

  it('never falls back to renderer-level navigation for external evidence', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });

    fireEvent.click(screen.getByRole('button', { name: /^PR #2172 Open/i }));

    expect((await screen.findByRole('alert')).textContent).toContain(
      'The installed Linux shell cannot safely open Inbox links.'
    );
  });

  it('routes Inbox actions to exact targets with macOS-equivalent labels', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });
    replaceFixtureActions([
      {
        id: 'project',
        kind: 'open_project',
        title: 'Project action',
        value: '/home/alberto/BurnBar',
        isPrimary: true
      },
      {
        id: 'session',
        kind: 'open_session_log',
        title: 'Session action',
        value: 'Codex:session-1',
        isPrimary: false
      },
      {
        id: 'resume',
        kind: 'resume_conversation',
        title: 'Resume action',
        value: 'Claude Code:conversation-2',
        isPrimary: false
      }
    ]);

    fireEvent.click(await screen.findByRole('button', { name: 'Open project' }));
    expect(useShellStore.getState().routeHash).toBe(projectWorkspaceRouteHash('/home/alberto/BurnBar'));

    fireEvent.click(screen.getByRole('button', { name: 'Open session' }));
    expect(useShellStore.getState().routeHash).toBe(activityConversationRouteHash('Codex:session-1'));

    fireEvent.click(screen.getByRole('button', { name: 'Resume conversation' }));
    expect(useShellStore.getState().routeHash).toBe(
      activityConversationRouteHash('Claude Code:conversation-2')
    );
  });

  it('reports an invalid daemon action target instead of navigating generically', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });
    replaceFixtureActions([{
      id: 'invalid-project',
      kind: 'open_project',
      title: 'Invalid project',
      value: '../relative/project',
      isPrimary: true
    }]);

    fireEvent.click(await screen.findByRole('button', { name: 'Open project' }));

    expect((await screen.findByRole('alert')).textContent).toMatch(/absolute, normalized linux path/i);
    expect(useShellStore.getState().route).toBe('inbox');
  });

  it('groups active rows into attention, today, and earlier without changing row order', () => {
    const now = new Date(2026, 7, 11, 15).getTime();
    const rows = [
      presentationRow({
        id: 'attention',
        title: 'Approval is blocking the release',
        priority: 1,
        lastSeenAt: new Date(2026, 7, 11, 14).toISOString()
      }),
      presentationRow({
        id: 'today',
        title: 'Review the latest usage change',
        priority: 3,
        lastSeenAt: new Date(2026, 7, 11, 8).toISOString()
      }),
      presentationRow({
        id: 'earlier',
        title: 'Clean up an older branch',
        priority: 4,
        lastSeenAt: new Date(2026, 7, 10, 20).toISOString()
      })
    ];

    expect(inboxListSections(rows, 'active', now).map((section) => ({
      label: section.label,
      titles: section.rows.map((row) => row.item.summary.title)
    }))).toEqual([
      { label: 'Needs attention', titles: ['Approval is blocking the release'] },
      { label: 'Today', titles: ['Review the latest usage change'] },
      { label: 'Earlier', titles: ['Clean up an older branch'] }
    ]);
  });

  it('matches the macOS closed section for resolved and archived filters', () => {
    const row = presentationRow({
      id: 'closed',
      title: 'A completed release item',
      priority: 1,
      lastSeenAt: new Date(2026, 7, 11, 14).toISOString()
    });

    expect(inboxListSections([row], 'resolved')).toEqual([
      { id: 'closed', label: 'Closed', rows: [row] }
    ]);
    expect(inboxListSections([row], 'archived')).toEqual([
      { id: 'closed', label: 'Closed', rows: [row] }
    ]);
  });
});
