import { Banner } from '../../components/Banner.js';
import type { AppVersionInfo } from '../../tauriBridge.js';

const CHANNEL_LABEL: Record<AppVersionInfo['packageChannel'], string> = {
  deb: 'Debian package (.deb)',
  appimage: 'AppImage',
  unknown: 'Unknown channel'
};


export function VersionGrid({ info }: { info: AppVersionInfo }) {
  const mismatch = info.shellVersion !== info.daemonVersion;
  return (
    <>
      {mismatch ? (
        <Banner tone="degraded" role="alert">
          Shell and daemon versions differ — restart after your package manager replaces both binaries, or
          reconnect from Overview if only the daemon was updated.
        </Banner>
      ) : null}
      <dl className="fact-grid p09-version-grid">
        <div className="fact">
          <dt>Shell version</dt>
          <dd className="mono">{info.shellVersion}</dd>
        </div>
        <div className="fact">
          <dt>Daemon version</dt>
          <dd className="mono">{info.daemonVersion}</dd>
        </div>
        <div className="fact">
          <dt>Package channel</dt>
          <dd>{CHANNEL_LABEL[info.packageChannel]}</dd>
        </div>
      </dl>
    </>
  );
}