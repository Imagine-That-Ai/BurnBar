import type { DaemonStatusCopy } from '../daemonStatusCopy.js';

/**
 * Daemon health pill. Contract pinned by the evidence harness:
 * `.status-pill[role="status"]` with tone class `ok | warn | err`.
 * GEOMETRY-FROZEN: no extra inline children — pill wrap width feeds the
 * nav pixel map used by the packaged desktop-session smoke (see app.css).
 */
export function StatusPill({ status }: { status: DaemonStatusCopy }) {
  return (
    <div className={`status-pill ${status.tone}`} role="status" title={status.detail}>
      {status.label}
    </div>
  );
}
