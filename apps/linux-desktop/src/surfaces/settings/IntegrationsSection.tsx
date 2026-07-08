import { FailureStateList } from '../../components/FailureStateList.js';
import { StatusPill } from '../../components/StatusPill.js';
import type { DaemonStatusCopy } from '../../daemonStatusCopy.js';
import { useIntegrationsStore } from '../../state/integrationsStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import type { IntegrationKind, IntegrationState, IntegrationStatus } from '../../tauriBridge.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';

const ORDER: IntegrationKind[] = [
  'smart_hub_bridge',
  'google_cast',
  'home_assistant',
  'pixel_clock',
  'awtrix_http'
];

const FALLBACK_LABELS: Record<IntegrationKind, string> = {
  smart_hub_bridge: 'SmartHub Bridge',
  google_cast: 'Google Cast',
  home_assistant: 'Home Assistant',
  pixel_clock: 'PixelClock',
  awtrix_http: 'AWTRIX HTTP'
};

const STATUS_COPY: Record<IntegrationState, DaemonStatusCopy> = {
  connected: { ok: true, label: 'Connected', tone: 'ok', detail: 'Live control path is reachable.' },
  configured: { ok: true, label: 'Configured', tone: 'warn', detail: 'Configured or discovered; live control is not proven.' },
  unavailable: { ok: false, label: 'Unavailable', tone: 'err', detail: 'Linux dependency or daemon-side configuration is missing.' },
  disabled: { ok: true, label: 'Disabled', tone: 'warn', detail: 'Disabled by daemon configuration.' }
};

function rowsByKind(rows: IntegrationStatus[]): Map<IntegrationKind, IntegrationStatus[]> {
  const grouped = new Map<IntegrationKind, IntegrationStatus[]>();
  for (const row of rows) {
    grouped.set(row.kind, [...(grouped.get(row.kind) ?? []), row]);
  }
  return grouped;
}

function capabilityCopy(row: IntegrationStatus): string {
  if (row.dependency) return row.dependency;
  switch (row.kind) {
    case 'google_cast':
      return 'Install avahi-utils for mDNS browse.';
    case 'home_assistant':
      return 'Set OPENBURNBAR_HOME_ASSISTANT_URL for authenticated control.';
    case 'smart_hub_bridge':
      return 'Start the Linux SmartHub bridge on loopback HTTP.';
    case 'pixel_clock':
      return 'Attach AWTRIX hardware, start the runtime agent, or provide OPENBURNBAR_PIXELCLOCK_URL.';
    case 'awtrix_http':
      return 'Install avahi-utils and keep the AWTRIX HTTP endpoint reachable.';
  }
}

function IntegrationRow({ row }: { row: IntegrationStatus }) {
  const pill = STATUS_COPY[row.state];
  return (
    <li className={`integration-row-shell integration-row-shell--${row.state}`}>
      <SettingRow
        label={row.label}
        description={row.detail}
        iconGlyph={row.kind === 'pixel_clock' || row.kind === 'awtrix_http' ? '▦' : '⊞'}
        control={<StatusPill status={{ ...pill, detail: row.detail }} />}
        readOnlyNote={row.configLocation ?? 'Configure via openburnbar-cli devices parity --json'}
      />
      {row.state === 'unavailable' ? (
        <FailureStateList
          cases={[
            {
              id: `integration-${row.kind}`,
              title: 'Capability absent',
              recovery: capabilityCopy(row)
            }
          ]}
        />
      ) : null}
      {row.docsHref ? (
        <a className="integration-doc-link" href={row.docsHref}>
          Read smart-display device QA notes for {row.label}
        </a>
      ) : null}
    </li>
  );
}

export function IntegrationsSection() {
  const status = useIntegrationsStore((s) => s.status);
  const loading = useIntegrationsStore((s) => s.loading);
  const error = useIntegrationsStore((s) => s.error);
  const loadStatus = useIntegrationsStore((s) => s.loadStatus);

  useLaneLoad(loadStatus);

  if (loading && !status) {
    return (
      <SettingGroup title="Smart display integrations" id="settings-integrations" sectionHeader>
        <p className="muted" aria-busy="true">
          Loading smart-display integration status…
        </p>
      </SettingGroup>
    );
  }

  if (error && !status) {
    return (
      <SettingGroup title="Smart display integrations" id="settings-integrations" sectionHeader>
        <p className="muted settings-tab-lede">
          Linux reads smart-device capability from the packaged CLI, not from browser-side network probes.
        </p>
        <FailureStateList
          cases={[
            {
              id: 'integrations-status-unavailable',
              title: 'Integration status unavailable',
              recovery: error
            }
          ]}
        />
      </SettingGroup>
    );
  }

  const rows = status?.integrations ?? [];
  if (rows.length === 0) {
    return (
      <SettingGroup title="Smart display integrations" id="settings-integrations" sectionHeader>
        <p className="muted">No integrations configured.</p>
      </SettingGroup>
    );
  }

  const grouped = rowsByKind(rows);
  return (
    <section className="integrations-section" aria-label="Smart display integrations">
      <p className="muted settings-tab-lede">
        Read-only Linux parity for SmartHub, Cast, Home Assistant, PixelClock, and AWTRIX. Configure and probe from
        the daemon CLI; this settings view does not collect credentials or contact devices directly.
      </p>
      {ORDER.map((kind) => {
        const kindRows = grouped.get(kind) ?? [];
        if (kindRows.length === 0) return null;
        return (
          <SettingGroup key={kind} title={FALLBACK_LABELS[kind]} id={`settings-integrations-${kind}`} sectionHeader>
            <ul className="integration-row-list">
              {kindRows.map((row) => (
                <IntegrationRow key={`${row.kind}-${row.state}-${row.label}`} row={row} />
              ))}
            </ul>
          </SettingGroup>
        );
      })}
    </section>
  );
}
