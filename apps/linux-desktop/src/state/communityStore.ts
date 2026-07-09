import { create } from 'zustand';
import type { CommunityLiveData } from '../community/types.js';
import { useLaneLoad } from './useLaneLoad.js';
import { useShellStore } from './shellStore.js';

type CommunityLiveState = {
  liveData: CommunityLiveData | null;
  loading: boolean;
  error: string | null;
  load(): Promise<void>;
};

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : 'Community live data is unavailable.';
}

function hasLivePayload(data: CommunityLiveData | null): boolean {
  return Boolean(data?.shareSnapshot) || Boolean(data?.leaderboards?.length);
}

export const useCommunityStore = create<CommunityLiveState>()((set) => ({
  liveData: null,
  loading: false,
  error: null,

  async load() {
    const bridge = useShellStore.getState().bridge;
    if (!bridge?.communityLiveData) {
      set({ liveData: null, loading: false, error: null });
      return;
    }

    set({ loading: true, error: null });
    try {
      const liveData = await bridge.communityLiveData();
      set({
        liveData: hasLivePayload(liveData) ? liveData : null,
        loading: false,
        error: null,
      });
    } catch (error) {
      set({
        liveData: null,
        loading: false,
        error: errorMessage(error),
      });
    }
  },
}));

/**
 * Mount-time Community live-data loader. The Linux shell remains local-first:
 * no Firebase SDK is imported here. Packaged hosts may relay the owner
 * share_snapshot and public leaderboard docs through the optional Tauri bridge;
 * missing/older daemons degrade to the existing preview state without fabricating ranks.
 */
export function useCommunityLiveData(): {
  liveData: CommunityLiveData | null;
  loading: boolean;
  error: string | null;
} {
  const liveData = useCommunityStore((state) => state.liveData);
  const loading = useCommunityStore((state) => state.loading);
  const error = useCommunityStore((state) => state.error);
  const load = useCommunityStore((state) => state.load);
  useLaneLoad(load);
  return { liveData, loading, error };
}
