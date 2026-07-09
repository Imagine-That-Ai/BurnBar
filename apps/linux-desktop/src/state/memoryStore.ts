import { create } from 'zustand';
import { fixtureMemoryReviewInbox } from '../daemonFixture.js';
import type { MemoryReviewInbox, MemoryReviewStatus } from '../tauriBridge.js';
import { useShellStore } from './shellStore.js';

const OFFLINE_ERROR = 'Packaged shell required for live memory review.';
const REVIEW_STATUS_STORAGE_KEY = 'openburnbar.linux.memoryReviewStatus.v1';

function readStoredStatuses(): Record<string, MemoryReviewStatus> {
  try {
    const raw = localStorage.getItem(REVIEW_STATUS_STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, MemoryReviewStatus>;
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function writeStoredStatus(id: string, status: MemoryReviewStatus): void {
  const map = readStoredStatuses();
  map[id] = status;
  localStorage.setItem(REVIEW_STATUS_STORAGE_KEY, JSON.stringify(map));
}

function applyStoredStatuses(inbox: MemoryReviewInbox): MemoryReviewInbox {
  const stored = readStoredStatuses();
  return {
    ...inbox,
    items: inbox.items.map((item) => {
      const override = stored[item.id];
      return override ? { ...item, status: override } : item;
    })
  };
}

export type MemoryDecisionState = {
  pending: boolean;
  error: string | null;
};

export type MemoryState = {
  inbox: MemoryReviewInbox | null;
  loading: boolean;
  error: string | null;
  decisionById: Record<string, MemoryDecisionState>;
  loadInbox(): Promise<void>;
  decide(id: string, status: Exclude<MemoryReviewStatus, 'pending'>): Promise<void>;
};

export const useMemoryStore = create<MemoryState>()((set, get) => ({
  inbox: null,
  loading: false,
  error: null,
  decisionById: {},

  async loadInbox() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({
        inbox: applyStoredStatuses(fixtureMemoryReviewInbox()),
        loading: false,
        error: null
      });
      return;
    }
    if (!bridge) {
      set({ inbox: null, loading: false, error: OFFLINE_ERROR });
      return;
    }
    set({ loading: true, error: null });
    try {
      const inbox = await bridge.memoryReviewInbox();
      set({ inbox: applyStoredStatuses(inbox), loading: false, error: null });
    } catch (e) {
      set({
        inbox: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Failed to load memory review inbox'
      });
    }
  },

  async decide(id, status) {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      writeStoredStatus(id, status);
      set((state) => ({
        inbox: state.inbox
          ? {
              ...state.inbox,
              items: state.inbox.items.map((item) => (item.id === id ? { ...item, status } : item))
            }
          : state.inbox,
        decisionById: {
          ...state.decisionById,
          [id]: { pending: false, error: null }
        }
      }));
      return;
    }
    if (!bridge) {
      set((state) => ({
        decisionById: {
          ...state.decisionById,
          [id]: { pending: false, error: OFFLINE_ERROR }
        }
      }));
      return;
    }
    set((state) => ({
      decisionById: {
        ...state.decisionById,
        [id]: { pending: true, error: null }
      }
    }));
    try {
      const item = get().inbox?.items.find((entry) => entry.id === id);
      if (bridge.memorySetStatus) {
        if (status === 'rejected') {
          // Permanent forget — not a soft "return to pending".
          await bridge.memorySetStatus('reject', { memoryID: id });
        } else {
          // Already-durable rows (approved status, audit hash, or recall origin):
          // local-mark only — never re-persist via remember (Issue 9).
          const alreadyDurable =
            item?.status === 'approved' ||
            Boolean(item?.auditHash) ||
            /recall/i.test(item?.sourceLabel ?? '');
          if (alreadyDurable) {
            writeStoredStatus(id, 'approved');
            set((state) => ({
              inbox: state.inbox
                ? {
                    ...state.inbox,
                    items: state.inbox.items.map((entry) =>
                      entry.id === id ? { ...entry, status: 'approved' as const } : entry
                    )
                  }
                : state.inbox,
              decisionById: {
                ...state.decisionById,
                [id]: { pending: false, error: null }
              }
            }));
            return;
          }
          // "Save as durable memory" via remember — fail closed without body.
          const text = item?.body?.trim() ?? '';
          if (!text) {
            throw new Error(
              'Cannot save memory without body text. Re-recall the item or paste the fact to remember.'
            );
          }
          if (text.startsWith('approved:')) {
            throw new Error('Refusing invented approved:<id> placeholder text.');
          }
          // Dedupe: if another inbox item already approved with same body, local-mark only.
          const duplicate = get().inbox?.items.some(
            (entry) =>
              entry.id !== id &&
              entry.status === 'approved' &&
              entry.body.trim() === text
          );
          if (duplicate) {
            writeStoredStatus(id, 'approved');
            set((state) => ({
              inbox: state.inbox
                ? {
                    ...state.inbox,
                    items: state.inbox.items.map((entry) =>
                      entry.id === id ? { ...entry, status: 'approved' as const } : entry
                    )
                  }
                : state.inbox,
              decisionById: {
                ...state.decisionById,
                [id]: { pending: false, error: null }
              }
            }));
            return;
          }
          await bridge.memorySetStatus('approve', {
            text,
            kind: item?.kind || 'note',
            tags: ['linux-shell-save'],
            confidence: item?.confidence ?? 1
          });
        }
      } else if (bridge.memoryReviewDecision) {
        if (status === 'approved') {
          const text = item?.body?.trim() ?? '';
          if (!text) {
            throw new Error(
              'Cannot approve/save memory without body text (fail-closed).'
            );
          }
        }
        await bridge.memoryReviewDecision(id, status);
      } else {
        throw new Error('No memory decision bridge method available.');
      }
      writeStoredStatus(id, status);
      await get().loadInbox();
      set((state) => ({
        decisionById: {
          ...state.decisionById,
          [id]: { pending: false, error: null }
        }
      }));
    } catch (e) {
      set((state) => ({
        decisionById: {
          ...state.decisionById,
          [id]: {
            pending: false,
            error: e instanceof Error ? e.message : 'Memory decision failed'
          }
        }
      }));
    }
  }
}));
