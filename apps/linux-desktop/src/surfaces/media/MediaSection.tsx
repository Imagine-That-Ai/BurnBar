import { useEffect, useState } from 'react';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useMediaStore } from '../../state/mediaStore.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { DeviceRow } from './DeviceRow.js';
import { MercuryCallHUD } from './MercuryCallHUD.js';
import { SessionStatusCard } from './SessionStatusCard.js';
import type { MercuryFileTransfer, MercuryViewerCapability } from '../../tauriBridge.js';

export function MediaSection() {
  const status = useMediaStore((s) => s.status);
  const loadState = useMediaStore((s) => s.loadState);
  const mediaControlState = useMediaStore((s) => s.mediaControlState);
  const mediaControlReason = useMediaStore((s) => s.mediaControlReason);
  const mediaRpcControlState = useMediaStore((s) => s.mediaRpcControlState);
  const mediaRpcControlReason = useMediaStore((s) => s.mediaRpcControlReason);
  const error = useMediaStore((s) => s.error);
  const callError = useMediaStore((s) => s.callError);
  const callState = useMediaStore((s) => s.callState);
  const stageEvents = useMediaStore((s) => s.stageEvents);
  const fileTransfers = useMediaStore((s) => s.fileTransfers);
  const fileCapabilityAvailable = useMediaStore((s) => s.fileCapabilityAvailable);
  const fileDownloadDirectory = useMediaStore((s) => s.fileDownloadDirectory);
  const fileError = useMediaStore((s) => s.fileError);
  const fileBusyTransferID = useMediaStore((s) => s.fileBusyTransferID);
  const load = useMediaStore((s) => s.load);
  const stopLiveSessionObservers = useMediaStore((s) => s.stopLiveSessionObservers);
  const acceptCall = useMediaStore((s) => s.acceptCall);
  const declineCall = useMediaStore((s) => s.declineCall);
  const endCall = useMediaStore((s) => s.endCall);
  const acceptFileTransfer = useMediaStore((s) => s.acceptFileTransfer);
  const declineFileTransfer = useMediaStore((s) => s.declineFileTransfer);
  const sendFileTransfer = useMediaStore((s) => s.sendFileTransfer);
  const scriptFixtureFileTransfer = useMediaStore((s) => s.scriptFixtureFileTransfer);
  const daemonStatus = useDaemonStatusCopy();
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const viewerCapability = status?.viewerCapability;
  const viewerUnavailable = Boolean(viewerCapability && !viewerCapability.available);

  useLaneLoad(load);

  useEffect(() => stopLiveSessionObservers, [stopLiveSessionObservers]);

  let body;
  if (loadState === 'loading' || loadState === 'idle') {
    body = <p className="muted">Loading Mercury media status…</p>;
  } else if (loadState === 'offline') {
    body = (
      <OfflineNotice
        status={daemonStatus}
        summary="Connect the packaged shell to read Mercury media state from the daemon."
        fixtureMode={fixtureMode}
      />
    );
  } else if (loadState === 'capability-absent') {
    body = (
      viewerUnavailable ? (
        <MercuryViewerCapabilityNotice capability={viewerCapability!} />
      ) : (
        <div className="p12-absent-state" role="status">
          <span className="p12-absent-kicker">Capability absent</span>
          <h3>Media engine is unavailable in this Linux session</h3>
          <p>
            The shell checked the daemon's Mercury capability contract. Repair the daemon, runtime
            directory, portal, or codec dependency reported in Support, then retry this route.
          </p>
        </div>
      )
    );
  } else if (loadState === 'error') {
    body = (
      <div className="banner degraded" role="alert">
        {error ?? 'Media status request failed'}
      </div>
    );
  } else if (loadState === 'empty') {
    body = (
      <>
        {viewerUnavailable ? <MercuryViewerCapabilityNotice capability={viewerCapability!} /> : null}
        <p className="muted">No paired devices — pair from the mobile app.</p>
        <MercuryFileTransferPanel
          transfers={fileTransfers}
          capabilityAvailable={fileCapabilityAvailable}
          downloadDirectory={fileDownloadDirectory}
          error={fileError}
          busyTransferID={fileBusyTransferID}
          fixtureMode={fixtureMode}
          onAccept={(transfer) => void acceptFileTransfer(transfer.transferID, transfer.manifestID)}
          onDecline={(transfer) => void declineFileTransfer(transfer.transferID, transfer.manifestID)}
          onSend={(path) => void sendFileTransfer(path)}
          onScriptFixture={scriptFixtureFileTransfer}
        />
      </>
    );
  } else {
    body = (
      <>
        {viewerUnavailable ? <MercuryViewerCapabilityNotice capability={viewerCapability!} /> : null}
        {status?.capabilityAvailable && mediaControlState === 'degraded' ? (
          <MercuryReceiveOnlyNotice reason={mediaControlReason} />
        ) : null}
        {!viewerUnavailable ? (
          <MercuryCallHUD
            call={callState}
            error={callError}
            controlState={mediaRpcControlState}
            controlReason={mediaRpcControlReason}
            onAccept={(requestId) => void acceptCall(requestId)}
            onDecline={(requestId) => void declineCall(requestId)}
            onEnd={() => void endCall()}
          />
        ) : null}
        {status?.activeSession ? (
          <SessionStatusCard session={status.activeSession} events={stageEvents} />
        ) : (
          <p className="muted">No active Mercury media session.</p>
        )}
        <ul className="p12-device-list" aria-label="Paired Mercury devices">
          {status?.pairedDevices.map((device) => <DeviceRow key={device.id} device={device} />)}
        </ul>
        <MercuryFileTransferPanel
          transfers={fileTransfers}
          capabilityAvailable={fileCapabilityAvailable}
          downloadDirectory={fileDownloadDirectory}
          error={fileError}
          busyTransferID={fileBusyTransferID}
          fixtureMode={fixtureMode}
          onAccept={(transfer) => void acceptFileTransfer(transfer.transferID, transfer.manifestID)}
          onDecline={(transfer) => void declineFileTransfer(transfer.transferID, transfer.manifestID)}
          onSend={(path) => void sendFileTransfer(path)}
          onScriptFixture={scriptFixtureFileTransfer}
        />
      </>
    );
  }

  return (
    <section className="p12-media-section" aria-labelledby="p12-media-title">
      <div className="p12-section-head">
        <div>
          <h2 id="p12-media-title">Mercury media</h2>
          <p>Calls, screen sharing, paired devices, and encrypted file transfer.</p>
        </div>
        <span className="p12-media-chip">
          {loadState === 'ready'
            ? fixtureMode
              ? 'fixture transcript'
              : 'live daemon'
            : loadState === 'capability-absent'
              ? 'daemon capability'
              : 'observe + stage'}
        </span>
      </div>
      {body}
    </section>
  );
}

function MercuryViewerCapabilityNotice({ capability }: { capability: MercuryViewerCapability }) {
  return (
    <div className="p12-absent-state p12-viewer-absent" role="status">
      <span className="p12-absent-kicker">Viewer unavailable</span>
      <h3>Calls and screen sharing are paused on this Linux session</h3>
      <p>{viewerCapabilityReason(capability)}</p>
      {capability.installHint ? <p className="p12-viewer-install-hint">{capability.installHint}</p> : null}
      <small>File transfer remains available when the daemon advertises it.</small>
    </div>
  );
}

function MercuryReceiveOnlyNotice({ reason }: { reason: string | null }) {
  return (
    <div className="p12-absent-state p12-viewer-absent" role="status">
      <span className="p12-absent-kicker">Media stream receive-only</span>
      <p>{reason ?? 'The Linux media socket does not accept shell-originated control frames.'}</p>
      <small>Authenticated daemon controls remain available for supported calls and transfers.</small>
    </div>
  );
}

function viewerCapabilityReason(capability: MercuryViewerCapability): string {
  switch (capability.status) {
    case 'built_without_gstreamer':
      return 'This Linux build was compiled without the GStreamer viewer feature.';
    case 'gstreamer_backend_unavailable':
      return 'The GStreamer runtime is not available to the packaged shell.';
    case 'gstreamer_vp9_decoder_missing':
      return 'The GStreamer runtime is present, but its VP9 decoder is missing.';
    case 'gstreamer_video_sink_missing':
      return 'The GStreamer runtime is present, but no native video sink is registered.';
    case 'unknown':
      return capability.reason ?? 'The packaged shell cannot verify a native Mercury video viewer.';
    case 'available':
      return 'The native Mercury viewer is ready.';
  }
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function filePhaseLabel(transfer: MercuryFileTransfer): string {
  switch (transfer.phase) {
    case 'pendingAccept':
      return 'Pending accept';
    case 'downloading':
      return 'Downloading';
    case 'sending':
      return 'Sending';
    case 'offered':
      return 'Offered';
    case 'completed':
      return 'Completed';
    case 'declined':
      return 'Declined';
    case 'failed':
      return 'Failed';
    default:
      return transfer.phase;
  }
}

function filePeerLabel(transfer: MercuryFileTransfer): string {
  return transfer.peer?.name ?? (transfer.direction === 'inbound' ? 'Paired phone' : 'Paired device');
}

function MercuryFileTransferPanel({
  transfers,
  capabilityAvailable,
  downloadDirectory,
  error,
  busyTransferID,
  fixtureMode,
  onAccept,
  onDecline,
  onSend,
  onScriptFixture
}: {
  transfers: MercuryFileTransfer[];
  capabilityAvailable: boolean | null;
  downloadDirectory: string | null;
  error: string | null;
  busyTransferID: string | null;
  fixtureMode: boolean;
  onAccept: (transfer: MercuryFileTransfer) => void;
  onDecline: (transfer: MercuryFileTransfer) => void;
  onSend: (path: string) => void;
  onScriptFixture: () => void;
}) {
  const [sendPath, setSendPath] = useState('');
  const canUseFiles = capabilityAvailable === true || fixtureMode;
  const pendingOffers = transfers.filter((transfer) => transfer.direction === 'inbound' && transfer.phase === 'pendingAccept');
  const rows = transfers.filter((transfer) => transfer.phase !== 'pendingAccept');
  return (
    <section className="p12-file-panel" aria-label="Mercury file transfers">
      <div className="p12-file-panel-head">
        <div>
          <h3>File transfer</h3>
          <p>{downloadDirectory ? `Downloads: ${downloadDirectory}` : 'Downloads path unavailable'}</p>
        </div>
        <span className="p12-media-chip">
          {canUseFiles ? (fixtureMode ? 'fixture transfer' : 'iroh-blobs') : 'capability absent'}
        </span>
      </div>
      {capabilityAvailable === false && !fixtureMode ? (
        <div className="p12-file-absent" role="status">
          File transfer RPCs are unavailable on this daemon build.
        </div>
      ) : null}
      {error ? (
        <div className="banner degraded p12-file-error" role="alert">
          {error}
        </div>
      ) : null}
      {pendingOffers.map((transfer) => (
        <section className="p12-file-offer" key={transferKey(transfer)} aria-label="Incoming file offer">
          <div>
            <span className="p12-call-kicker">Incoming file</span>
            <h4>{transfer.filename}</h4>
            <p>
              {formatBytes(transfer.size)} from {filePeerLabel(transfer)}
            </p>
          </div>
          <div className="p12-call-actions">
            <button
              type="button"
              onClick={() => onAccept(transfer)}
              disabled={!canUseFiles || busyTransferID === transfer.transferID}
            >
              Accept file
            </button>
            <button
              type="button"
              className="ghost danger"
              onClick={() => onDecline(transfer)}
              disabled={!canUseFiles || busyTransferID === transfer.transferID}
            >
              Decline file
            </button>
          </div>
        </section>
      ))}
      <form
        className="p12-file-send"
        onSubmit={(event) => {
          event.preventDefault();
          onSend(sendPath);
        }}
      >
        <label>
          <span>File path</span>
          <input
            value={sendPath}
            onChange={(event) => setSendPath(event.currentTarget.value)}
            placeholder="/home/alberto/Downloads/report.pdf"
            disabled={!canUseFiles}
          />
        </label>
        <button type="submit" disabled={!canUseFiles || sendPath.trim().length === 0 || busyTransferID === 'send'}>
          Send file
        </button>
        {fixtureMode ? (
          <button type="button" className="ghost" onClick={onScriptFixture}>
            Script transfer
          </button>
        ) : null}
      </form>
      {rows.length > 0 ? (
        <ul className="p12-file-list" aria-label="Mercury file transfer history">
          {rows.map((transfer) => (
            <li className={`p12-file-row is-${transfer.phase}`} key={transferKey(transfer)}>
              <div>
                <strong>{transfer.filename}</strong>
                <small>
                  {filePhaseLabel(transfer)} · {transfer.direction} · {formatBytes(transfer.progress.bytesTransferred)} /{' '}
                  {formatBytes(transfer.progress.bytesTotal || transfer.size)}
                </small>
                {transfer.localPath ? <code>{transfer.localPath}</code> : null}
                {transfer.detail || transfer.errorCode ? <em>{transfer.detail ?? transfer.errorCode}</em> : null}
              </div>
              <progress max={1} value={transfer.progress.fraction} aria-label={`${transfer.filename} progress`} />
            </li>
          ))}
        </ul>
      ) : pendingOffers.length === 0 ? (
        <p className="muted">No file transfers.</p>
      ) : null}
    </section>
  );
}

function transferKey(transfer: MercuryFileTransfer): string {
  return transfer.transferID || transfer.manifestID;
}
