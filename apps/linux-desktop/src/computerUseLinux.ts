export type ComputerUseTarget =
  | 'VAL-CU-001'
  | 'VAL-CU-002'
  | 'VAL-CU-003'
  | 'VAL-MEDIA-001'
  | 'VAL-MOBILE-001'
  | 'VAL-SEC-003';

export type AdapterKind = 'capture' | 'input' | 'audit' | 'halt' | 'media' | 'mobile';

export type AdapterStatus = 'ready' | 'probe-required' | 'blocked';

export type LinuxComputerUseAdapter = {
  id: string;
  kind: AdapterKind;
  target: ComputerUseTarget;
  protocol: string;
  productPath: string;
  requiresConsent: boolean;
  requiresApproval: boolean;
  status: AdapterStatus;
  unavailableMeans: string;
};

export type PermissionState = {
  id: string;
  target: ComputerUseTarget;
  state: 'approved' | 'denied' | 'degraded' | 'revoked' | 'blocked';
  uiLabel: string;
  evidence: string;
};

export type TrustMode = 'manual' | 'step' | 'trusted';

export type InputAction = {
  id: string;
  kind: 'pointer.move' | 'pointer.click' | 'key.type' | 'scroll';
  x?: number;
  y?: number;
  text?: string;
};

export type DenyRegion = {
  id: string;
  x: number;
  y: number;
  width: number;
  height: number;
};

export type InputPolicyContext = {
  adapterId: string;
  adapterAvailable: boolean;
  approved: boolean;
  approvalId?: string;
  trustMode: TrustMode;
  requestedTrustMode?: TrustMode;
  approvalSource: 'local' | 'mobile' | 'trusted_scope';
  denyRegions: DenyRegion[];
  actionsInWindow: number;
  rateLimitPerWindow: number;
};

export type InputDecision = {
  actionId: string;
  adapterId: string;
  allowed: boolean;
  reason: string;
  audit: {
    actionKind: string;
    approvedBy: 'mac' | 'phone' | 'trusted_scope' | 'denied';
    approvalId: string | null;
    trustMode: TrustMode;
    denyReason: string | null;
  };
};

export type ReplayCase = {
  id: string;
  action: InputAction;
  context: InputPolicyContext;
  decision: InputDecision;
};

export type MobileWireFrame = {
  id: string;
  direction: 'mobile-to-linux' | 'linux-to-mobile';
  type: string;
  protocolVersion: number;
  linuxCapabilityMetadata?: Record<string, string | boolean | number>;
  backwardCompatibility: 'unchanged-frame' | 'additive-capability-only';
};

export type MediaCodecTrace = {
  id: string;
  target: ComputerUseTarget;
  stage: string;
  codec: 'hevc' | 'h264' | 'opus' | 'media-frame-v1' | 'media-frame-v2';
  delivery: 'iroh-stream' | 'iroh-datagram' | 'shell-hot-path';
  backpressure: 'none' | 'dropped-delta' | 'paused-producer';
  observation: string;
};

const TRUST_ORDER: TrustMode[] = ['manual', 'step', 'trusted'];

export function linuxComputerUseAdapters(): LinuxComputerUseAdapter[] {
  return [
    {
      id: 'wayland-portal-pipewire',
      kind: 'capture',
      target: 'VAL-CU-001',
      protocol: 'xdg-desktop-portal ScreenCast + PipeWire',
      productPath: 'Tauri shell -> portal session request -> PipeWire node',
      requiresConsent: true,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'blocked evidence row; no global Wayland scraping fallback'
    },
    {
      id: 'x11-scrot-fallback',
      kind: 'capture',
      target: 'VAL-CU-001',
      protocol: 'X11 screenshot fallback',
      productPath: 'XDG_SESSION_TYPE=x11 -> scoped capture after local approval',
      requiresConsent: false,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'degraded capture unavailable until X11 tools are present'
    },
    {
      id: 'libei',
      kind: 'input',
      target: 'VAL-CU-002',
      protocol: 'libei/libeis remote-desktop input',
      productPath: 'portal-approved input session when compositor exposes libei',
      requiresConsent: true,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'blocked evidence row; do not substitute keylogging'
    },
    {
      id: 'at-spi2',
      kind: 'input',
      target: 'VAL-CU-002',
      protocol: 'AT-SPI2 accessibility action adapter',
      productPath: 'org.a11y.Bus scoped accessibility actions',
      requiresConsent: true,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'blocked evidence row when accessibility bus is unavailable'
    },
    {
      id: 'uinput-policy',
      kind: 'input',
      target: 'VAL-CU-002',
      protocol: 'uinput with device permission policy',
      productPath: '/dev/uinput only when explicitly provisioned by installer policy',
      requiresConsent: true,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'blocked evidence row when /dev/uinput is absent or not writable'
    },
    {
      id: 'x11-xtest',
      kind: 'input',
      target: 'VAL-CU-002',
      protocol: 'XTEST fallback',
      productPath: 'X11-only xdotool/XTEST action after approval, deny-region, and rate checks',
      requiresConsent: false,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'degraded input unavailable when XTEST is missing'
    },
    {
      id: 'audit-signed-head',
      kind: 'audit',
      target: 'VAL-SEC-003',
      protocol: 'SHA-256 chain + Ed25519 signed terminal head',
      productPath: 'OpenBurnBarComputerUseCore audit schema mirrored by Linux evidence writer',
      requiresConsent: false,
      requiresApproval: false,
      status: 'ready',
      unavailableMeans: 'fail closed; signed head is mandatory'
    },
    {
      id: 'panic-halt',
      kind: 'halt',
      target: 'VAL-CU-003',
      protocol: 'app, daemon CLI, mobile control, system hook',
      productPath: 'shared session coordinator closes capture, input, media, and audit resources',
      requiresConsent: false,
      requiresApproval: false,
      status: 'ready',
      unavailableMeans: 'platform limitation row for unavailable global hooks'
    },
    {
      id: 'iroh-mercury-media',
      kind: 'media',
      target: 'VAL-MEDIA-001',
      protocol: 'openburnbar/1 + openburnbar/mercury/audio/1',
      productPath: 'crates/openburnbar-iroh + OpenBurnBarMedia frame codecs',
      requiresConsent: false,
      requiresApproval: true,
      status: 'probe-required',
      unavailableMeans: 'blocked row when no codec/device/LAN surface is available'
    },
    {
      id: 'mobile-control-replay',
      kind: 'mobile',
      target: 'VAL-MOBILE-001',
      protocol: 'HermesRealtimeRelayFrame control.* and media.* frames',
      productPath: 'iOS/Android phone control senders with additive Linux capability metadata',
      requiresConsent: false,
      requiresApproval: true,
      status: 'ready',
      unavailableMeans: 'use protocol replay when no device is attached'
    }
  ];
}

export function permissionStateRows(): PermissionState[] {
  return [
    {
      id: 'portal-requested',
      target: 'VAL-CU-001',
      state: 'degraded',
      uiLabel: 'Portal capture pending',
      evidence: 'No frame is accepted until portal approval returns a PipeWire node.'
    },
    {
      id: 'portal-denied',
      target: 'VAL-CU-001',
      state: 'denied',
      uiLabel: 'Capture denied',
      evidence: 'Denial keeps session readable and disables capture/input controls.'
    },
    {
      id: 'portal-revoked',
      target: 'VAL-CU-001',
      state: 'revoked',
      uiLabel: 'Capture revoked',
      evidence: 'Revocation closes capture and moves the session to degraded state.'
    },
    {
      id: 'input-approved',
      target: 'VAL-CU-002',
      state: 'approved',
      uiLabel: 'Input approved',
      evidence: 'Approved actions still pass deny-region, trust, and rate-limit gates.'
    },
    {
      id: 'panic-active',
      target: 'VAL-CU-003',
      state: 'approved',
      uiLabel: 'Panic halt armed',
      evidence: 'Halt paths close capture, input, media, and append a terminal audit row.'
    }
  ];
}

function containsPoint(region: DenyRegion, x: number, y: number): boolean {
  return x >= region.x
    && y >= region.y
    && x < region.x + region.width
    && y < region.y + region.height;
}

function trustRank(mode: TrustMode): number {
  return TRUST_ORDER.indexOf(mode);
}

export function evaluateInputAction(action: InputAction, context: InputPolicyContext): InputDecision {
  let allowed = true;
  let reason = 'approved';

  if (!context.adapterAvailable) {
    allowed = false;
    reason = 'adapter_unavailable';
  } else if (!context.approved) {
    allowed = false;
    reason = 'local_approval_required';
  } else if (
    context.requestedTrustMode
    && context.approvalSource === 'mobile'
    && trustRank(context.requestedTrustMode) > trustRank(context.trustMode)
  ) {
    allowed = false;
    reason = 'mobile_cannot_elevate_trust';
  } else if (
    typeof action.x === 'number'
    && typeof action.y === 'number'
    && context.denyRegions.some((region) => containsPoint(region, action.x as number, action.y as number))
  ) {
    allowed = false;
    reason = 'deny_region';
  } else if (context.actionsInWindow >= context.rateLimitPerWindow) {
    allowed = false;
    reason = 'rate_limited';
  }

  const approvedBy = !allowed
    ? 'denied'
    : context.approvalSource === 'mobile'
      ? 'phone'
      : context.approvalSource === 'trusted_scope'
        ? 'trusted_scope'
        : 'mac';

  return {
    actionId: action.id,
    adapterId: context.adapterId,
    allowed,
    reason,
    audit: {
      actionKind: action.kind,
      approvedBy,
      approvalId: allowed ? context.approvalId ?? null : null,
      trustMode: context.trustMode,
      denyReason: allowed ? null : reason
    }
  };
}

export function inputPolicyReplay(): ReplayCase[] {
  const denyRegions: DenyRegion[] = [
    { id: 'password-field', x: 90, y: 90, width: 140, height: 60 }
  ];
  const base: InputPolicyContext = {
    adapterId: 'x11-xtest',
    adapterAvailable: true,
    approved: true,
    approvalId: 'approval-local-1',
    trustMode: 'step',
    approvalSource: 'local',
    denyRegions,
    actionsInWindow: 0,
    rateLimitPerWindow: 3
  };
  const cases: Array<{ id: string; action: InputAction; context: InputPolicyContext }> = [
    {
      id: 'approved-action',
      action: { id: 'move-1', kind: 'pointer.move', x: 40, y: 40 },
      context: base
    },
    {
      id: 'denied-region',
      action: { id: 'click-denied-1', kind: 'pointer.click', x: 120, y: 120 },
      context: base
    },
    {
      id: 'denied-no-permission',
      action: { id: 'type-no-permission-1', kind: 'key.type', text: 'blocked' },
      context: { ...base, adapterAvailable: false, adapterId: 'libei', approvalId: 'approval-local-2' }
    },
    {
      id: 'downgrade-only-mobile',
      action: { id: 'mobile-trust-elevate-1', kind: 'pointer.click', x: 30, y: 30 },
      context: {
        ...base,
        approvalId: 'approval-phone-1',
        approvalSource: 'mobile',
        trustMode: 'manual',
        requestedTrustMode: 'trusted'
      }
    },
    {
      id: 'rate-limited',
      action: { id: 'scroll-rate-1', kind: 'scroll', x: 20, y: 20 },
      context: { ...base, actionsInWindow: 3 }
    }
  ];
  return cases.map((replay) => ({
    ...replay,
    decision: evaluateInputAction(replay.action, replay.context)
  }));
}

export function mobileProtocolReplayFrames(): MobileWireFrame[] {
  return [
    {
      id: 'approval-request',
      direction: 'linux-to-mobile',
      type: 'controlApprovalRequest',
      protocolVersion: 1,
      linuxCapabilityMetadata: {
        peerPlatform: 'linux',
        capture: 'portal-pipewire',
        input: 'libei-atspi-uinput-xtest'
      },
      backwardCompatibility: 'additive-capability-only'
    },
    {
      id: 'approval-deny',
      direction: 'mobile-to-linux',
      type: 'controlApprovalResponse',
      protocolVersion: 1,
      backwardCompatibility: 'unchanged-frame'
    },
    {
      id: 'phone-input',
      direction: 'mobile-to-linux',
      type: 'controlInputIntent',
      protocolVersion: 1,
      linuxCapabilityMetadata: {
        trustChange: 'downgrade-only'
      },
      backwardCompatibility: 'additive-capability-only'
    },
    {
      id: 'media-frame',
      direction: 'linux-to-mobile',
      type: 'mediaStreamFrame',
      protocolVersion: 1,
      linuxCapabilityMetadata: {
        mediaFrameHeader: 'shared-18-byte-v1-with-cursor-extension',
        codecFallback: 'h264'
      },
      backwardCompatibility: 'additive-capability-only'
    },
    {
      id: 'panic-halt',
      direction: 'mobile-to-linux',
      type: 'controlPanicHalt',
      protocolVersion: 1,
      backwardCompatibility: 'unchanged-frame'
    }
  ];
}

export function mediaCodecTrace(): MediaCodecTrace[] {
  return [
    {
      id: 'screen-hevc',
      target: 'VAL-MEDIA-001',
      stage: 'screen-share-keyframe',
      codec: 'hevc',
      delivery: 'iroh-stream',
      backpressure: 'none',
      observation: 'Preferred when Linux encoder and mobile decoder both advertise HEVC.'
    },
    {
      id: 'screen-h264-fallback',
      target: 'VAL-MEDIA-001',
      stage: 'screen-share-fallback',
      codec: 'h264',
      delivery: 'iroh-stream',
      backpressure: 'paused-producer',
      observation: 'Fallback preserves ordered GOP stream when HEVC is unavailable.'
    },
    {
      id: 'audio-opus',
      target: 'VAL-MEDIA-001',
      stage: 'call-audio',
      codec: 'opus',
      delivery: 'iroh-datagram',
      backpressure: 'dropped-delta',
      observation: 'Audio remains datagram-first; stale packets are dropped before queue growth.'
    },
    {
      id: 'agent-watch-v1',
      target: 'VAL-MEDIA-001',
      stage: 'agent-watch-frame',
      codec: 'media-frame-v1',
      delivery: 'shell-hot-path',
      backpressure: 'dropped-delta',
      observation: 'Cursor metadata stays the shared four-byte extension; no Linux-only fork.'
    },
    {
      id: 'agent-watch-v2-negotiated',
      target: 'VAL-MEDIA-001',
      stage: 'future-extension-negotiation',
      codec: 'media-frame-v2',
      delivery: 'iroh-stream',
      backpressure: 'paused-producer',
      observation: 'V2 metadata is negotiated before use so v1 mobile clients keep v1 payload semantics.'
    }
  ];
}

export function safetyInvariantSummary(): Record<string, boolean> {
  return {
    noGlobalKeylogging: true,
    noSilentAutopilot: true,
    waylandCaptureRequiresPortalConsent: true,
    mobileTrustDowngradeOnly: true,
    signedHeadRequired: true,
    unavailableHardwareBecomesBlockedEvidence: true
  };
}
