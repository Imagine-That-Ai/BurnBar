import { create } from 'zustand';
import { fixtureMissionList } from '../daemonFixture.js';
import { useShellStore } from './shellStore.js';
import type {
  ApprovalDecision,
  MissionCreateInput,
  MissionDetail,
  MissionListResult,
  MissionHealthResult
} from '../tauriBridge.js';

export type ApprovalDecisionState = {
  pending: boolean;
  error: string | null;
};

export type MissionsState = {
  data: MissionListResult | null;
  loading: boolean;
  error: string | null;
  approvalById: Record<string, ApprovalDecisionState>;
  cancelById: Record<string, ApprovalDecisionState>;
  detailById: Record<string, MissionDetail>;
  detailLoadingById: Record<string, boolean>;
  detailErrorById: Record<string, string | null>;
  healthById: Record<string, MissionHealthResult>;
  healthLoadingById: Record<string, boolean>;
  healthErrorById: Record<string, string | null>;
  creating: boolean;
  createError: string | null;
  load(): Promise<void>;
  inspect(id: string): Promise<MissionDetail | null>;
  loadHealth(id: string): Promise<MissionHealthResult | null>;
  decide(approvalId: string, decision: ApprovalDecision): Promise<void>;
  cancel(id: string, note?: string): Promise<boolean>;
  create(input: MissionCreateInput): Promise<boolean>;
  resetApprovals(): void;
};

export const useMissionsStore = create<MissionsState>()((set, get) => ({
  data: null,
  loading: false,
  error: null,
  approvalById: {},
  cancelById: {},
  detailById: {},
  detailLoadingById: {},
  detailErrorById: {},
  healthById: {},
  healthLoadingById: {},
  healthErrorById: {},
  creating: false,
  createError: null,

  resetApprovals() {
    set({ approvalById: {} });
  },

  async load() {
    const { fixtureMode, bridge } = useShellStore.getState();
    if (fixtureMode) {
      const data = fixtureMissionList();
      set({
        data,
        detailById: Object.fromEntries(data.missions.map((mission) => [mission.id, mission])),
        loading: false,
        error: null
      });
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
      set({
        data,
        detailById: Object.fromEntries(data.missions.map((mission) => [mission.id, mission])),
        loading: false,
        error: null
      });
    } catch (e) {
      set({
        data: null,
        loading: false,
        error: e instanceof Error ? e.message : 'Request failed'
      });
    }
  },

  async inspect(id) {
    const { bridge, fixtureMode } = useShellStore.getState();
    const cached = get().detailById[id] ?? get().data?.missions.find((mission) => mission.id === id);
    if (fixtureMode || !bridge || typeof bridge.missionGet !== 'function') {
      if (cached) set((s) => ({ detailById: { ...s.detailById, [id]: cached } }));
      return cached ?? null;
    }

    set((s) => ({
      detailLoadingById: { ...s.detailLoadingById, [id]: true },
      detailErrorById: { ...s.detailErrorById, [id]: null }
    }));
    try {
      const detail = await bridge.missionGet(id);
      if (!detail) throw new Error('Mission detail was not returned by the daemon.');
      set((s) => ({
        detailById: { ...s.detailById, [id]: detail },
        detailLoadingById: { ...s.detailLoadingById, [id]: false },
        detailErrorById: { ...s.detailErrorById, [id]: null }
      }));
      void get().loadHealth(id);
      return detail;
    } catch (e) {
      set((s) => ({
        detailLoadingById: { ...s.detailLoadingById, [id]: false },
        detailErrorById: {
          ...s.detailErrorById,
          [id]: e instanceof Error ? e.message : 'Mission detail failed'
        }
      }));
      return cached ?? null;
    }
  },

  async loadHealth(id) {
    const { bridge, fixtureMode } = useShellStore.getState();
    if (fixtureMode || !bridge || typeof bridge.missionHealth !== 'function') return null;
    set((s) => ({
      healthLoadingById: { ...s.healthLoadingById, [id]: true },
      healthErrorById: { ...s.healthErrorById, [id]: null }
    }));
    try {
      const result = await bridge.missionHealth(id);
      set((s) => ({
        healthById: { ...s.healthById, [id]: result },
        healthLoadingById: { ...s.healthLoadingById, [id]: false },
        healthErrorById: { ...s.healthErrorById, [id]: null }
      }));
      return result;
    } catch (e) {
      set((s) => ({
        healthLoadingById: { ...s.healthLoadingById, [id]: false },
        healthErrorById: {
          ...s.healthErrorById,
          [id]: e instanceof Error ? e.message : 'Mission health failed'
        }
      }));
      return null;
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

  async cancel(id, note) {
    const { bridge, fixtureMode } = useShellStore.getState();
    if (fixtureMode || !bridge || typeof bridge.missionCancel !== 'function') {
      set((s) => ({
        cancelById: {
          ...s.cancelById,
          [id]: { pending: false, error: 'Mission cancellation is unavailable in this shell.' }
        }
      }));
      return false;
    }

    set((s) => ({
      cancelById: { ...s.cancelById, [id]: { pending: true, error: null } }
    }));
    try {
      const detail = await bridge.missionCancel(id, note);
      if (detail) {
        set((s) => ({ detailById: { ...s.detailById, [id]: detail } }));
      }
      await get().load();
      set((s) => ({
        cancelById: { ...s.cancelById, [id]: { pending: false, error: null } }
      }));
      return true;
    } catch (e) {
      set((s) => ({
        cancelById: {
          ...s.cancelById,
          [id]: { pending: false, error: e instanceof Error ? e.message : 'Mission cancellation failed' }
        }
      }));
      return false;
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
