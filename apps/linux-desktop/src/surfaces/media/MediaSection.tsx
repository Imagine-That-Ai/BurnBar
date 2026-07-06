import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useMediaStore } from '../../state/mediaStore.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { DeviceRow } from './DeviceRow.js';
import { MercuryCallHUD } from './MercuryCallHUD.js';
import { SessionStatusCard } from './SessionStatusCard.js';

export function MediaSection() {
  const status = useMediaStore((s) => s.status);
  const loadState = useMediaStore((s) => s.loadState);
  const error = useMediaStore((s) => s.error);
  const callError = useMediaStore((s) => s.callError);
  const callState = useMediaStore((s) => s.callState);
  const stageEvents = useMediaStore((s) => s.stageEvents);
  const load = useMediaStore((s) => s.load);
  const acceptCall = useMediaStore((s) => s.acceptCall);
  const declineCall = useMediaStore((s) => s.declineCall);
  const endCall = useMediaStore((s) => s.endCall);
  const daemonStatus = useDaemonStatusCopy();
  const fixtureMode = useShellStore((s) => s.fixtureMode);

  useLaneLoad(load);

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
      <div className="p12-absent-state" role="status">
        <span className="p12-absent-kicker">Capability absent</span>
        <h3>Media engine not yet available on this Linux build</h3>
        <p>
          The shell checked the daemon for `daemon.media.status`. This build has no Mercury peer-list
          RPC yet, so Linux is correctly showing observe-only readiness instead of simulated media.
        </p>
      </div>
    );
  } else if (loadState === 'error') {
    body = (
      <div className="banner degraded" role="alert">
        {error ?? 'Media status request failed'}
      </div>
    );
  } else if (loadState === 'empty') {
    body = <p className="muted">No paired devices — pair from the mobile app.</p>;
  } else {
    body = (
      <>
        <MercuryCallHUD
          call={callState}
          error={callError}
          onAccept={(requestId) => void acceptCall(requestId)}
          onDecline={(requestId) => void declineCall(requestId)}
          onEnd={() => void endCall()}
        />
        {status?.activeSession ? (
          <SessionStatusCard session={status.activeSession} events={stageEvents} />
        ) : (
          <p className="muted">No active Mercury media session.</p>
        )}
        <ul className="p12-device-list" aria-label="Paired Mercury devices">
          {status?.pairedDevices.map((device) => <DeviceRow key={device.id} device={device} />)}
        </ul>
      </>
    );
  }

  return (
    <section className="p12-media-section" aria-labelledby="p12-media-title">
      <div className="p12-section-head">
        <div>
          <h2 id="p12-media-title">Mercury media</h2>
          <p>Paired devices and media-control stage readout.</p>
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
