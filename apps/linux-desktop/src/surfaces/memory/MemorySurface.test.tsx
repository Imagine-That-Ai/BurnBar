// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useShellStore } from '../../state/shellStore.js';
import { useMemoryStore } from '../../state/memoryStore.js';
import { useSystemStore } from '../../state/systemStore.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
import { MemorySurface } from './MemorySurface.js';

function resetStores(): void {
  useShellStore.setState({ bridge: null, fixtureMode: false });
  useSystemStore.setState({
    config: null,
    db: null,
    projects: null,
    memory: null,
    loading: false,
    error: null
  });
  useMemoryStore.setState({
    inbox: null,
    loading: false,
    error: null,
    decisionById: {}
  });
  localStorage.removeItem('openburnbar.linux.memoryReviewStatus.v1');
}

describe('MemorySurface', () => {
  beforeEach(resetStores);
  afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
  });

  it('renders review inbox with filter chips and recall boundaries in fixture mode', () => {
    useShellStore.setState({ fixtureMode: true });
    const { container } = render(<MemorySurface />);
    expect(screen.getByText('Approve what to remember')).toBeTruthy();
    expect(screen.getByRole('group', { name: /memory review filter/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /pending/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /approved/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /rejected/i })).toBeTruthy();
    expect(screen.getByRole('button', { name: /^all$/i })).toBeTruthy();
    expect(screen.queryByText(/until the review inbox ships/i)).toBeNull();
    expect(container.querySelectorAll('.system-scope-chip').length).toBeGreaterThan(0);
    expect(screen.getByText(/live daemon memory boundaries|fixture transcript/i)).toBeTruthy();
    expect(screen.getByRole('heading', { name: 'Audit trail' })).toBeTruthy();
    const auditList = screen.getByRole('list', { name: 'Memory audit events' });
    expect(auditList).toBeTruthy();
    expect(within(auditList).getByText('Approved')).toBeTruthy();
    expect(within(auditList).getByText(/by fixture/)).toBeTruthy();
  });

  it('shows empty inbox copy when fixture boundaries are empty', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    vi.spyOn(useMemoryStore.getState(), 'loadInbox').mockImplementation(async () => {});
    useShellStore.setState({ fixtureMode: true });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    useMemoryStore.setState({ inbox: { items: [], auditEvents: [] }, loading: false, error: null });
    render(<MemorySurface />);
    expect(screen.getByText('No memory items pending review')).toBeTruthy();
    expect(screen.getByText('No memory boundaries configured')).toBeTruthy();
  });

  it('shows loading skeleton', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useSystemStore.setState({ loading: true, memory: null });
    const { container } = render(<MemorySurface />);
    expect(container.querySelector('.system-skeleton')).toBeTruthy();
  });

  it('shows offline notice', () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useShellStore.setState({ bridge: null, fixtureMode: false });
    useSystemStore.setState({ memory: null, loading: false, error: null });
    render(<MemorySurface />);
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('shows error with retry', () => {
    const spy = vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    useShellStore.setState({ bridge: {} as never, fixtureMode: false });
    useSystemStore.setState({ memory: null, loading: false, error: 'memory failed' });
    render(<MemorySurface />);
    fireEvent.click(screen.getByRole('button', { name: /retry/i }));
    expect(spy).toHaveBeenCalled();
  });

  it('approves a pending memory in fixture mode', () => {
    useShellStore.setState({ fixtureMode: true });
    render(<MemorySurface />);
    const row = screen.getByText(/Prefer Rust for daemon IPC/i).closest('article');
    expect(row).toBeTruthy();
    fireEvent.click(within(row!).getByRole('button', { name: /save as memory/i }));
    fireEvent.click(screen.getByRole('button', { name: /^approved$/i }));
    expect(screen.getAllByText('Approved').length).toBeGreaterThan(0);
  });

  it('renders daemon-owned statuses and forgets through memorySetStatus', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    const memorySetStatus = vi.fn().mockResolvedValue({});
    const memoryReviewInbox = vi.fn().mockResolvedValue({
      items: [
        {
          id: 'mem-live-1',
          body: 'Use daemon RPCs for Linux parity wiring.',
          kind: 'fact',
          confidence: 0.9,
          sourceLabel: 'Daemon memory recall',
          status: 'approved',
          canApprove: false
        }
      ],
      auditEvents: []
    });
    const bridge = {
      memoryReviewInbox,
      memorySetStatus
    } as unknown as LinuxShellBridge;
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    render(<MemorySurface />);
    fireEvent.click(screen.getByRole('button', { name: /^approved$/i }));
    await waitFor(() => expect(screen.getByText(/Use daemon RPCs/i)).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: /forget permanently/i }));
    await waitFor(() =>
      expect(memorySetStatus).toHaveBeenCalledWith('forget', { memoryID: 'mem-live-1' })
    );
  });

  it('shows pending quarantine rows with approve and reject actions', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    const memoryReviewInbox = vi.fn().mockResolvedValue({
      items: [
        {
          id: 'mem-pending',
          body: 'User prefers compact review cards.',
          kind: 'preference',
          confidence: 0.8,
          sourceLabel: 'Daemon memory quarantine',
          status: 'pending',
          canApprove: true
        }
      ],
      auditEvents: []
    });
    const memorySetStatus = vi.fn().mockResolvedValue({});
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    useShellStore.setState({
      bridge: { memoryReviewInbox, memorySetStatus } as unknown as LinuxShellBridge,
      fixtureMode: false
    });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    render(<MemorySurface />);
    await waitFor(() => expect(screen.getByText(/compact review cards/i)).toBeTruthy());
    fireEvent.click(screen.getByRole('button', { name: /save as memory/i }));
    await waitFor(() =>
      expect(memorySetStatus).toHaveBeenCalledWith(
        'approve',
        expect.objectContaining({ memoryID: 'mem-pending' })
      )
    );
  });

  it('shows degraded memory RPC errors without fixture fallback', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    const bridge = {
      memoryReviewInbox: vi.fn().mockResolvedValue({
        items: [],
        auditEvents: [],
        degradedReason: 'Project memory is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH.'
      })
    } as unknown as LinuxShellBridge;
    useShellStore.setState({ bridge, fixtureMode: false });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    render(<MemorySurface />);
    await waitFor(() => {
      expect(screen.getByRole('alert').textContent).toContain('Project memory is not available');
    });
  });

  it('renders daemon audit events with honest unknown timestamps and bounded identifiers', async () => {
    vi.spyOn(useSystemStore.getState(), 'loadMemory').mockImplementation(async () => {});
    const longAuditID = `audit-${'event-'.repeat(24)}`;
    const memoryReviewInbox = vi.fn().mockResolvedValue({
      items: [],
      auditEvents: [{
        id: longAuditID,
        action: 'unexpected-action',
        actor: 'daemon-worker',
        at: 'not-a-timestamp',
        subjectId: 'mem-unknown'
      }]
    });
    useShellStore.setState({
      bridge: { memoryReviewInbox } as unknown as LinuxShellBridge,
      fixtureMode: false
    });
    useSystemStore.setState({ memory: [], loading: false, error: null });
    render(<MemorySurface />);

    await waitFor(() => expect(screen.getByRole('list', { name: 'Memory audit events' })).toBeTruthy());
    expect(screen.getByText('unexpected-action')).toBeTruthy();
    expect(screen.getByText('Time unavailable')).toBeTruthy();
    expect(screen.getByText(/Subject mem-unknown/)).toBeTruthy();
    expect(screen.getByText(`Event ${longAuditID.slice(0, 117)}…`)).toBeTruthy();
  });
});
