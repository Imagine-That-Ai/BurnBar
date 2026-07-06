import { create } from 'zustand';
import { fixtureMissionList } from '../daemonFixture.js';
import { useShellStore } from './shellStore.js';
import type { ApprovalDecision, MissionCreateInput, MissionListResult } from '../tauriBridge.js';

export type ApprovalDecisionState = {
  pending: boolean;
  error: string | null;
};

export type MissionsState = {
  data: MissionListResult | null;
  loading: boolean;
  error: string | null;
  approvalById: Record<string, ApprovalDecisionState>;
  creating: boolean;
  createError: string | null;
  load(): Promise<void>;
  decide(approvalId: string, decision: ApprovalDecision): Promise<void>;
  create(input: MissionCreateInput): Promise<boolean>;
  resetApprovals(): void;
};

export const useMissionsStore = create<MissionsState>()((set, get) => ({
  data: null,
  loading: false,
  error: null,
  approvalById: {},
  creating: false,
  createError: null,

  resetApprovals() {
    set({ approvalById: {} });
  },

  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      set({ data: fixtureMissionList(), loading: false, error: null });
      return;
    }
    if (!bridge) {
      set({
        data: null,
        loading: false,
        error: 'Packaged shell required for live data.'
      });
      return;
    }
    set({ loading: true, error: null });
    try {
      const data = await bridge.missionList();
      set({ data, loading: false, error: null });
    } catch (e) {
      set({
        data: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async decide(approvalId, decision) {
    const { bridge, fixtureMode } = useShellStore.getState();
    if (fixtureMode || !bridge) {
      set((s) => ({
        approvalById: {
          ...s.approvalById,
          [approvalId]: { pending: false, error: 'Packaged shell required for live decisions.' }
        }
      }));
      return;
    }

    set((s) => ({
      approvalById: {
        ...s.approvalById,
        [approvalId]: { pending: true, error: null }
      }
    }));

    try {
      const approval = get().data?.pendingApprovals.find((item) => item.id === approvalId);
      const missionId = approval?.missionId && approval.missionId !== 'unknown' ? approval.missionId : approvalId;
      await bridge.missionApprovalDecision(missionId, decision);
      await get().load();
      set((s) => ({
        approvalById: {
          ...s.approvalById,
          [approvalId]: { pending: false, error: null }
        }
      }));
    } catch (e) {
      const message = e instanceof Error ? e.message : 'Decision failed';
      set((s) => ({
        approvalById: {
          ...s.approvalById,
          [approvalId]: { pending: false, error: message }
        }
      }));
    }
  },

  async create(input) {
    const { bridge, fixtureMode } = useShellStore.getState();
    if (fixtureMode || !bridge) {
      set({ creating: false, createError: 'Packaged shell required for live mission creation.' });
      return false;
    }
    set({ creating: true, createError: null });
    try {
      await bridge.missionCreate(input);
      await get().load();
      set({ creating: false, createError: null });
      return true;
    } catch (e) {
      set({
        creating: false,
        createError: e instanceof Error ? e.message : 'Mission creation failed'
      });
      return false;
    }
  }
}));
