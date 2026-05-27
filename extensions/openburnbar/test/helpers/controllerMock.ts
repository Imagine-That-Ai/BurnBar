import { vi } from 'vitest';

import type { OpenBurnBarControllerSnapshotSource } from '../../src/state/controller';
import type { OpenBurnBarState } from '../../src/types';

export function createTestState(
  partialState: Partial<OpenBurnBarState> = {}
): OpenBurnBarState {
  return {
    connectionStatus: 'connecting',
    clientAttached: false,
    daemonRuns: [],
    pendingToolCalls: [],
    recentUsage: [],
    runs: [],
    ...partialState
  };
}

export function createSnapshotController(
  partialState: Partial<OpenBurnBarState> = {}
): OpenBurnBarControllerSnapshotSource {
  const snapshot: OpenBurnBarState = {
    connectionStatus: 'connecting',
    clientAttached: false,
    daemonRuns: [],
    pendingToolCalls: [],
    recentUsage: [],
    runs: [],
    ...partialState
  };

  return {
    snapshot,
    onDidChangeState: vi.fn().mockReturnValue({ dispose: vi.fn() })
  };
}
