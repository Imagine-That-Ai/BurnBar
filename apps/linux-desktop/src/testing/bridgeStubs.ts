import type {
  DatabaseIndexActionResult,
  DatabaseWorkspaceStatus,
  IntegrationsStatus,
  MercuryMediaCapability,
  MemoryReviewInbox,
  MercuryMediaStatus,
  MercuryMediaSessionState,
  MissionCreateInput,
  MissionListResult
} from '../tauriBridge.js';

// Shared honest-empty defaults for full-shape LinuxShellBridge test mocks.
// Each lane that extends the bridge contract adds its members here once,
// so existing full-mock tests keep type-checking without per-file edits.
export const emptyMediaStatus = (): Promise<MercuryMediaStatus> =>
  Promise.resolve({ capabilityAvailable: false, pairedDevices: [] });

export const emptyMediaSessionState = (): Promise<MercuryMediaSessionState> =>
  Promise.resolve({ phase: 'capability-absent', kind: 'call', capabilityAvailable: false });

export const emptyMediaAction = (_requestId?: string): Promise<MercuryMediaSessionState> =>
  Promise.resolve({ phase: 'capability-absent', kind: 'call', capabilityAvailable: false });

export const emptyMediaCapability = (): Promise<MercuryMediaCapability> =>
  Promise.resolve({
    available: false,
    renderer: 'unknown',
    canReceiveCalls: false,
    canViewScreenShare: false
  });

export const emptyIntegrationsStatus = (): Promise<IntegrationsStatus> =>
  Promise.resolve({ integrations: [] });

export const emptyMissionCreate = (
  _input: MissionCreateInput
): Promise<MissionListResult['missions'][number] | null> => Promise.resolve(null);

export const emptyMemoryReviewInbox = (): Promise<MemoryReviewInbox> =>
  Promise.resolve({ items: [], auditEvents: [] });

export const emptyMemoryReviewDecision = (): Promise<void> => Promise.resolve();

export const emptyDatabaseWorkspaceStatus = (): Promise<DatabaseWorkspaceStatus> =>
  Promise.resolve({
    sourceLabel: 'test stub',
    projectID: 'test-project',
    artifactCount: 0,
    chunkCount: 0,
    symbolCount: 0,
    referenceCount: 0,
    callEdgeCount: 0,
    rejectedCount: 0,
    storageByteCount: 0,
    storageBudgetBytes: 0,
    storageWithinBudget: true,
    productionReady: false,
    productionReadinessReasons: [],
    parserAvailable: false,
    databaseEncrypted: false,
    hostedCodeToolsEnabled: false,
    semanticAvailable: false,
    files: [],
    languages: [],
    diagnostics: [],
    degradedReasons: []
  });

export const emptyDatabaseIndexAction = (): Promise<DatabaseIndexActionResult> =>
  Promise.resolve({ projectID: 'test-project', projectRoot: '/tmp/test', indexedFiles: 0 });

export const emptyGatewayAuthToken = (): Promise<string | null> => Promise.resolve(null);

export const bridgeStubDefaults = {
  gatewayAuthToken: emptyGatewayAuthToken,
  mediaStatus: emptyMediaStatus,
  mediaSessionState: emptyMediaSessionState,
  mediaAcceptCall: emptyMediaAction,
  mediaDeclineCall: emptyMediaAction,
  mediaEndCall: emptyMediaSessionState,
  mediaCapabilityGet: emptyMediaCapability,
  integrationsStatus: emptyIntegrationsStatus,
  missionCreate: emptyMissionCreate,
  memoryReviewInbox: emptyMemoryReviewInbox,
  memoryReviewDecision: emptyMemoryReviewDecision,
  databaseWorkspaceStatus: emptyDatabaseWorkspaceStatus,
  databaseIndexProject: emptyDatabaseIndexAction,
  databaseWatchProject: emptyDatabaseIndexAction
};
