import type {
  DatabaseIndexActionResult,
  DatabaseWorkspaceStatus,
  ComputerUsePanicHaltResult,
  IntegrationsStatus,
  MercuryMediaCapability,
  MercuryFileOfferListResponse,
  MercuryFileTransferActionRequest,
  MercuryFileTransferActionResponse,
  MercuryFileTransferSendRequest,
  MemoryReviewInbox,
  MercuryMediaStatus,
  MercuryMediaSessionState,
  MissionCreateInput,
  MissionListResult
} from '../tauriBridge.js';
import {
  RUNTIME_CAPABILITY_IDS,
  type RuntimeCapabilityManifest
} from '../runtimeCapabilities.js';

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

export const emptyMediaFileOfferList = (): Promise<MercuryFileOfferListResponse> =>
  Promise.resolve({ capabilityAvailable: false, transfers: [] });

export const emptyMediaFileAction = (
  _request?: MercuryFileTransferActionRequest | MercuryFileTransferSendRequest
): Promise<MercuryFileTransferActionResponse> =>
  Promise.resolve({ accepted: false, errorCode: 'capabilityAbsent' });

export const emptyIntegrationsStatus = (): Promise<IntegrationsStatus> =>
  Promise.resolve({ integrations: [] });

export const emptyMissionCreate = (
  _input: MissionCreateInput
): Promise<MissionListResult['missions'][number] | null> => Promise.resolve(null);

export const emptyMemoryReviewInbox = (): Promise<MemoryReviewInbox> =>
  Promise.resolve({ items: [], auditEvents: [] });

export const emptyMemoryReviewDecision = (): Promise<void> => Promise.resolve();

export const emptyMemorySetStatus = async (
  _action: string,
  _payload: Record<string, unknown>
): Promise<unknown> => ({ ok: true });

export const emptyToolApprovalRespond = async (): Promise<void> => {};

export const emptyComputerUse = async (
  _params?: Record<string, unknown>
): Promise<unknown> => ({ ok: false, reason: 'stub' });

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

export const emptyGatewayProbe = (): Promise<boolean> => Promise.resolve(false);
export const emptyGatewayChatStream = (): Promise<void> => Promise.resolve();
export const emptyGatewayChatCancel = (): Promise<void> => Promise.resolve();

export const emptyComputerUsePanicHalt = (): Promise<ComputerUsePanicHaltResult> =>
  Promise.resolve({
    sessionId: '*',
    endedAt: new Date(0).toISOString(),
    auditHeadHashHex: '',
    source: 'hotkey'
  });

export const makeAvailableRuntimeCapabilityManifest = (): RuntimeCapabilityManifest => ({
    schemaVersion: 1,
    catalogVersion: 'test',
    shellVersion: 'test',
    daemonVersion: 'test',
    daemonProtocolVersion: 1,
    sessionType: 'x11',
    desktop: 'test',
    capabilities: RUNTIME_CAPABILITY_IDS.map((id) => ({
      id,
      domain:
        id === 'updates.install'
          ? 'delivery'
          : id.startsWith('secrets.') || id === 'native.external-billing'
            ? 'security'
            : id.startsWith('computer-use.') ||
                id === 'media.mercury' ||
                id === 'smarthub.control' ||
                id === 'pet.overlay' ||
                id === 'text-expansion.system' ||
                id === 'portal.desktop' ||
                id === 'native.tray' ||
                id === 'native.notifications'
              ? 'platform'
              : 'product',
      state: 'available',
      reason: 'Available in the test bridge.',
      substitute: null,
      source: 'test-bridge'
    }))
  });

export const availableRuntimeCapabilities = (): Promise<RuntimeCapabilityManifest> =>
  Promise.resolve(makeAvailableRuntimeCapabilityManifest());

export const bridgeStubDefaults = {
  runtimeCapabilities: availableRuntimeCapabilities,
  gatewayProbe: emptyGatewayProbe,
  gatewayChatStream: emptyGatewayChatStream,
  gatewayChatCancel: emptyGatewayChatCancel,
  mediaStatus: emptyMediaStatus,
  mediaSessionState: emptyMediaSessionState,
  mediaAcceptCall: emptyMediaAction,
  mediaDeclineCall: emptyMediaAction,
  mediaEndCall: emptyMediaSessionState,
  mediaCapabilityGet: emptyMediaCapability,
  mediaFileOfferList: emptyMediaFileOfferList,
  mediaFileAccept: emptyMediaFileAction,
  mediaFileDecline: emptyMediaFileAction,
  mediaFileSend: emptyMediaFileAction,
  integrationsStatus: emptyIntegrationsStatus,
  missionCreate: emptyMissionCreate,
  memoryReviewInbox: emptyMemoryReviewInbox,
  memoryReviewDecision: emptyMemoryReviewDecision,
  memorySetStatus: emptyMemorySetStatus,
  toolApprovalRespond: emptyToolApprovalRespond,
  computerUseSessionStart: emptyComputerUse,
  computerUseInvoke: emptyComputerUse,
  computerUseApprovalPending: emptyComputerUse,
  computerUseApprovalRespond: emptyComputerUse,
  computerUsePanicHalt: emptyComputerUsePanicHalt,
  computerUseAuditExport: emptyComputerUse,
  databaseWorkspaceStatus: emptyDatabaseWorkspaceStatus,
  databaseIndexProject: emptyDatabaseIndexAction,
  databaseWatchProject: emptyDatabaseIndexAction
};
