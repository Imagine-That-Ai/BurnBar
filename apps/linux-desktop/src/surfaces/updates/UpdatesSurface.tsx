import { useLaneLoad } from '../../state/useLaneLoad.js';
import { FailureStateList } from '../../components/FailureStateList.js';
import { OfflineNotice } from '../../components/OfflineNotice.js';
import { useDaemonStatusCopy, useShellStore } from '../../state/shellStore.js';
import { useSupportStore } from '../../state/supportStore.js';
import { VersionGrid } from '../support/VersionGrid.js';
import { UpdateStatusCard } from './UpdateStatusCard.js';
import '../support/support.css';

const UPDATE_CASES = [
  {
    id: 'channel-unavailable',
    title: 'Update channel unavailable',
    recovery: 'Use the package manager transcript in Support; release packaging is handled outside this shell lane.'
  },
  {
    id: 'restart-required',
    title: 'Restart required',
    recovery: 'Quit from tray or Support after the package manager finishes replacing binaries.'
  }
];

const CHANNEL_CARD_COPY: Record<'deb' | 'rpm' | 'appimage' | 'unknown', string> = {
  deb: 'Installed via the Debian package channel; apt/dpkg owns upgrades.',
  rpm: 'Installed via the RPM package channel; dnf/rpm owns upgrades.',
  appimage: 'Installed as AppImage; replace the image file from your release source.',
  unknown: 'Package channel could not be determined; use your distro package manager or release notes.'
};

export function UpdatesSurface() {
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const status = useDaemonStatusCopy();
  const versionInfo = useSupportStore((s) => s.versionInfo);
  const versionLoading = useSupportStore((s) => s.versionLoading);
  const versionError = useSupportStore((s) => s.versionError);
  const loadVersion = useSupportStore((s) => s.loadVersion);
  const updateStatus = useSupportStore((s) => s.updateStatus);
  const updateLoading = useSupportStore((s) => s.updateLoading);
  const updateError = useSupportStore((s) => s.updateError);
  const checkUpdate = useSupportStore((s) => s.checkUpdate);

  useLaneLoad(loadVersion);

  if (versionLoading && !versionInfo) {
    return (
      <>
        <p className="muted">Loading package channel and version facts…</p>
        <FailureStateList cases={UPDATE_CASES} />
      </>
    );
  }

  if (versionError && !versionInfo) {
    return (
      <>
        <OfflineNotice
          status={status}
          summary="Updates needs the packaged shell to read version and channel facts."
          fixtureMode={fixtureMode}
        />
        <FailureStateList cases={UPDATE_CASES} />
      </>
    );
  }

  if (!versionInfo) {
    return (
      <>
        <OfflineNotice
          status={status}
          summary="Version facts are unavailable without the packaged shell or fixture mode."
          fixtureMode={fixtureMode}
        />
        <FailureStateList cases={UPDATE_CASES} />
      </>
    );
  }

  return (
    <>
      <p className="p09-updates-lede">
        Updates are delivered by your package manager — this shell does not download or install upgrades in-app.
      </p>
      <VersionGrid info={versionInfo} />
      <UpdateStatusCard
        status={updateStatus}
        loading={updateLoading}
        error={updateError}
        onCheck={() => void checkUpdate()}
      />
      <div className="p09-channel-card">
        <h3>Package channel</h3>
        <p>{CHANNEL_CARD_COPY[versionInfo.packageChannel]}</p>
      </div>
      <div className="p09-restart-guidance">
        <h3>Restart guidance</h3>
        <p>
          After your package manager replaces OpenBurnBar binaries, quit the app from the tray or Support, then
          launch again so shell and daemon versions stay aligned.
        </p>
      </div>
      <FailureStateList cases={UPDATE_CASES} />
    </>
  );
}
