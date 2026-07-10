// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { LinuxShellBridge, MemoryReviewInbox } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';
import { useMemoryStore } from './memoryStore.js';

const sampleInbox: MemoryReviewInbox = {
  items: [
    {
      id: 'mem-1',
      body: 'User prefers dark mode',
      kind: 'preference',
      confidence: 0.9,
      sourceLabel: 'chat',
      status: 'pending',
      canApprove: true
    },
    {
      id: 'mem-empty',
      body: '   ',
      kind: 'note',
      confidence: 0.5,
      sourceLabel: 'chat',
      status: 'pending',
      canApprove: true
    }
  ],
  auditEvents: []
};

function reset() {
  localStorage.clear();
  useShellStore.setState({
    fixtureMode: false,
    bridge: null,
    bridgeReady: true,
    health: null
  });
  useMemoryStore.setState({
    inbox: null,
    loading: false,
    error: null,
    decisionById: {}
  });
}

describe('memoryStore decide (memorySetStatus primary)', () => {
  beforeEach(reset);
  afterEach(reset);

  it('reject calls memorySetStatus reject with memoryID', async () => {
    const memorySetStatus = vi.fn().mockResolvedValue({});
    const memoryReviewInbox = vi.fn().mockResolvedValue(sampleInbox);
    useShellStore.setState({
      bridge: {
        memorySetStatus,
        memoryReviewInbox
      } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-1', 'rejected');
    expect(memorySetStatus).toHaveBeenCalledWith('reject', { memoryID: 'mem-1' });
    expect(useMemoryStore.getState().decisionById['mem-1']?.error).toBeNull();
  });

  it('approve with body calls memorySetStatus approve', async () => {
    const memorySetStatus = vi.fn().mockResolvedValue({});
    const memoryReviewInbox = vi.fn().mockResolvedValue(sampleInbox);
    useShellStore.setState({
      bridge: {
        memorySetStatus,
        memoryReviewInbox
      } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-1', 'approved');
    expect(memorySetStatus).toHaveBeenCalledWith(
      'approve',
      expect.objectContaining({ text: 'User prefers dark mode' })
    );
  });

  it('approve without body fails closed', async () => {
    const memorySetStatus = vi.fn();
    useShellStore.setState({
      bridge: { memorySetStatus, memoryReviewInbox: vi.fn() } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-empty', 'approved');
    expect(memorySetStatus).not.toHaveBeenCalled();
    expect(useMemoryStore.getState().decisionById['mem-empty']?.error).toMatch(/without body/i);
  });

  it('offline bridge records offline error', async () => {
    useShellStore.setState({ bridge: null, fixtureMode: false });
    await useMemoryStore.getState().decide('mem-1', 'rejected');
    expect(useMemoryStore.getState().decisionById['mem-1']?.error).toMatch(/Packaged shell/);
  });

  it('daemon-down surfaces decision error', async () => {
    const memorySetStatus = vi.fn().mockRejectedValue(new Error('daemon down'));
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-1', 'rejected');
    expect(useMemoryStore.getState().decisionById['mem-1']?.error).toMatch(/daemon down/);
  });

  it('falls back to memoryReviewDecision when memorySetStatus absent', async () => {
    const memoryReviewDecision = vi.fn().mockResolvedValue(undefined);
    const memoryReviewInbox = vi.fn().mockResolvedValue(sampleInbox);
    useShellStore.setState({
      bridge: {
        memoryReviewDecision,
        memoryReviewInbox
      } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-1', 'rejected');
    expect(memoryReviewDecision).toHaveBeenCalledWith('mem-1', 'rejected');
  });

  it('approve daemon-down surfaces rejection error', async () => {
    const memorySetStatus = vi.fn().mockRejectedValue(new Error('socket closed'));
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: sampleInbox });
    await useMemoryStore.getState().decide('mem-1', 'approved');
    expect(useMemoryStore.getState().decisionById['mem-1']?.error).toMatch(/socket closed/);
  });

  it('skips remember when item is already approved (no duplicate)', async () => {
    const memorySetStatus = vi.fn();
    const approvedInbox: MemoryReviewInbox = {
      items: [
        {
          id: 'mem-1',
          body: 'User prefers dark mode',
          kind: 'preference',
          confidence: 0.9,
          sourceLabel: 'chat',
          status: 'approved',
          canApprove: false
        }
      ],
      auditEvents: []
    };
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: approvedInbox });
    await useMemoryStore.getState().decide('mem-1', 'approved');
    expect(memorySetStatus).not.toHaveBeenCalled();
    expect(useMemoryStore.getState().decisionById['mem-1']?.error).toBeNull();
  });

  it('skips remember for recall-origin pending rows (already durable)', async () => {
    const memorySetStatus = vi.fn();
    const recallInbox: MemoryReviewInbox = {
      items: [
        {
          id: 'mem-recall',
          body: 'Already durable fact from daemon.memory.recall',
          kind: 'fact',
          confidence: 0.95,
          sourceLabel: 'Daemon memory recall',
          status: 'pending',
          canApprove: true,
          auditHash: 'abc123'
        }
      ],
      auditEvents: []
    };
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox: recallInbox });
    await useMemoryStore.getState().decide('mem-recall', 'approved');
    expect(memorySetStatus).not.toHaveBeenCalled();
  });

  it('refuses invented approved: placeholder text', async () => {
    const memorySetStatus = vi.fn();
    const inbox: MemoryReviewInbox = {
      items: [
        {
          id: 'mem-x',
          body: 'approved:mem-x',
          kind: 'note',
          confidence: 1,
          sourceLabel: 'user',
          status: 'pending',
          canApprove: true
        }
      ],
      auditEvents: []
    };
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox });
    await useMemoryStore.getState().decide('mem-x', 'approved');
    expect(memorySetStatus).not.toHaveBeenCalled();
    expect(useMemoryStore.getState().decisionById['mem-x']?.error).toMatch(/placeholder/i);
  });

  it('dedupes by matching already-approved body', async () => {
    const memorySetStatus = vi.fn();
    const inbox: MemoryReviewInbox = {
      items: [
        {
          id: 'mem-a',
          body: 'same body',
          kind: 'note',
          confidence: 1,
          sourceLabel: 'user',
          status: 'approved',
          canApprove: false
        },
        {
          id: 'mem-b',
          body: 'same body',
          kind: 'note',
          confidence: 1,
          sourceLabel: 'user',
          status: 'pending',
          canApprove: true
        }
      ],
      auditEvents: []
    };
    useShellStore.setState({
      bridge: { memorySetStatus } as unknown as LinuxShellBridge
    });
    useMemoryStore.setState({ inbox });
    await useMemoryStore.getState().decide('mem-b', 'approved');
    expect(memorySetStatus).not.toHaveBeenCalled();
  });
});
