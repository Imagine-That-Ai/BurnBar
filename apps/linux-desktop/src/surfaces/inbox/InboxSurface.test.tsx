// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useInboxStore } from '../../state/inboxStore.js';
import { useShellStore } from '../../state/shellStore.js';
import type { AIInboxPresentationRow } from '../../tauriBridge.js';
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
    route: 'inbox'
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

  it('does not fake memory, follow-up, or plan-memory authority', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });

    const rememberCandidate = screen.getByRole('button', { name: 'Remember this' });
    expect(rememberCandidate.hasAttribute('disabled')).toBe(true);
    expect(rememberCandidate.getAttribute('title')).toMatch(/daemon-authoritative/i);

    const followUp = screen.getByRole('button', { name: 'Follow up' });
    expect(followUp.hasAttribute('disabled')).toBe(true);
    expect(followUp.getAttribute('title')).toMatch(/cannot create/i);

    const rememberStep = screen.getByRole('button', { name: 'Remember' });
    expect(rememberStep.hasAttribute('disabled')).toBe(true);
    expect(rememberStep.getAttribute('title')).toMatch(/daemon-authoritative/i);
  });

  it('never falls back to renderer-level navigation for external evidence', async () => {
    render(<InboxSurface />);
    await screen.findByRole('heading', { name: 'PR #2172 is waiting on one approval' });

    fireEvent.click(screen.getByRole('button', { name: /^PR #2172 Open/i }));

    expect((await screen.findByRole('alert')).textContent).toContain(
      'The installed Linux shell cannot safely open Inbox links.'
    );
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
