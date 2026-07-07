import type { ConfigSnapshot } from '../../tauriBridge.js';
import type { DaemonStatusCopy } from '../../daemonStatusCopy.js';
import { readOnboarding } from '../../onboardingStore.js';
import { GlassAlert, GlassAlertStack, type GlassAlertSeverity } from '../../components/GlassAlert.js';
import type { SettingsTabId } from './settingsTabs.js';
import { SettingsIconTile } from './SettingsDrillRow.js';

type AttentionItem = {
  id: string;
  title: string;
  detail: string;
  iconGlyph: string;
  tint: string;
  tab: SettingsTabId;
};

function attentionSeverity(id: string): GlassAlertSeverity {
  if (id === 'secret-store') return 'error';
  return 'warning';
}

function buildAttentionItems(config: ConfigSnapshot | null, status: DaemonStatusCopy): AttentionItem[] {
  const items: AttentionItem[] = [];
  const ob = readOnboarding();
  if (!ob.completed) {
    items.push({
      id: 'onboarding',
      title: 'Finish first-run setup',
      detail: 'Daemon, Secret Service, and desktop limits need acknowledgement.',
      iconGlyph: '✓',
      tint: 'var(--color-tier-server-readable)',
      tab: 'general'
    });
  }
  if (config?.secretServiceStatus === 'locked' || config?.secretServiceStatus === 'unavailable') {
    items.push({
      id: 'secret-store',
      title: 'Secret Service locked or unavailable',
      detail: 'Unlock GNOME Keyring or KWallet before provider credentials can be stored.',
      iconGlyph: '⛨',
      tint: 'var(--color-seal-crimson)',
      tab: 'daemon'
    });
  }
  if (!status.ok && status.label !== 'Fixture') {
    items.push({
      id: 'daemon',
      title: status.label,
      detail: status.detail,
      iconGlyph: '⎔',
      tint: 'var(--color-tier-server-readable)',
      tab: 'daemon'
    });
  }
  return items;
}

export function SettingsHomeView({
  config,
  status,
  fixtureMode,
  onSelectTab
}: {
  config: ConfigSnapshot | null;
  status: DaemonStatusCopy;
  fixtureMode: boolean;
  onSelectTab: (tab: SettingsTabId) => void;
}) {
  const attention = buildAttentionItems(config, status);
  const daemonStatus = status.ok ? 'Connected' : status.label;
  const daemonTint = status.ok ? 'var(--color-tier-end-to-end)' : 'var(--color-tier-server-readable)';
  const secretStatus = config?.secretServiceStatus ?? 'unknown';
  const telemetry = config?.telemetryEnabled ? 'On' : 'Off';
  const privacy = config?.privacyOptIn ? 'On' : 'Off';
  const sourceNote = fixtureMode ? 'fixture transcript' : 'live daemon config snapshot';

  return (
    <div className="settings-home">
      <header className="settings-home-hero">
        <h2 className="settings-home-title">OpenBurnBar Settings</h2>
        <p className="muted settings-home-lede">
          Everything that matters at a glance. Pick a sidebar section to manage it, or use search to jump.
        </p>
        <p className="muted data-source">{`Data source: ${sourceNote}`}</p>
      </header>

      {attention.length > 0 ? (
        <section className="settings-home-attention" aria-labelledby="settings-attention-heading">
          <h3 id="settings-attention-heading" className="settings-home-kicker settings-home-kicker--warn">
            Needs your attention
          </h3>
          <GlassAlertStack>
            <ul className="settings-attention-list" style={{ display: 'contents', listStyle: 'none', margin: 0, padding: 0 }}>
              {attention.map((item) => (
                <li key={item.id}>
                  <GlassAlert
                    as="button"
                    severity={attentionSeverity(item.id)}
                    title={item.title}
                    description={item.detail}
                    iconGlyph={item.iconGlyph}
                    actionLabel="Fix"
                    role="status"
                    onClick={() => onSelectTab(item.tab)}
                  />
                </li>
              ))}
            </ul>
          </GlassAlertStack>
        </section>
      ) : null}

      <section className="settings-home-grid-section" aria-labelledby="settings-health-heading">
        <h3 id="settings-health-heading" className="settings-home-kicker">
          System health
        </h3>
        <div className="settings-status-grid">
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('daemon')}>
            <SettingsIconTile glyph="⎔" tint={daemonTint} size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Daemon</span>
              <span className="settings-status-card-value mono">{daemonStatus}</span>
            </span>
          </button>
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('agents')}>
            <SettingsIconTile glyph="◇" tint="var(--color-brass-core)" size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Providers</span>
              <span className="settings-status-card-value mono">Providers lane</span>
            </span>
          </button>
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('daemon')}>
            <SettingsIconTile glyph="⛨" tint="var(--color-tier-end-to-end)" size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Secret Service</span>
              <span className="settings-status-card-value mono">{secretStatus}</span>
            </span>
          </button>
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('data-privacy')}>
            <SettingsIconTile glyph="📡" tint="var(--color-tier-end-to-end)" size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Telemetry</span>
              <span className="settings-status-card-value mono">{telemetry}</span>
            </span>
          </button>
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('devices-and-sync')}>
            <SettingsIconTile glyph="⊞" tint="var(--color-tier-end-to-end)" size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Cloud sync</span>
              <span className="settings-status-card-value mono">Account lane</span>
            </span>
          </button>
          <button type="button" className="settings-status-card" onClick={() => onSelectTab('data-privacy')}>
            <SettingsIconTile glyph="🛡" tint="var(--color-tier-end-to-end)" size="sm" />
            <span className="settings-status-card-copy">
              <span className="settings-status-card-title">Privacy opt-in</span>
              <span className="settings-status-card-value mono">{privacy}</span>
            </span>
          </button>
        </div>
      </section>

      <section className="settings-home-tasks" aria-labelledby="settings-tasks-heading">
        <h3 id="settings-tasks-heading" className="settings-home-kicker">
          Quick actions
        </h3>
        <div className="settings-task-grid">
          {[
            {
              title: 'Add an Account',
              subtitle: 'Provider credentials and quota buckets',
              icon: '◇',
              tint: 'var(--color-brass-core)',
              tab: 'agents' as SettingsTabId
            },
            {
              title: 'Appearance',
              subtitle: 'Dark mode, skins, and motion',
              icon: '◐',
              tint: 'var(--color-tier-server-readable)',
              tab: 'general' as SettingsTabId
            },
            {
              title: 'Text Expansion',
              subtitle: 'Snippets and in-app previews',
              icon: '¶',
              tint: 'var(--color-tier-server-readable)',
              tab: 'text-expansion' as SettingsTabId
            },
            {
              title: 'Data & Privacy',
              subtitle: 'Telemetry, exports, and consent flags',
              icon: '⛨',
              tint: 'var(--color-tier-end-to-end)',
              tab: 'data-privacy' as SettingsTabId
            },
            {
              title: 'First-run setup',
              subtitle: 'Daemon, secrets, and desktop limits',
              icon: '✓',
              tint: 'var(--color-brass-bright)',
              tab: 'general' as SettingsTabId
            },
            {
              title: 'Support',
              subtitle: 'Diagnostics export and reconnect',
              icon: '⚠',
              tint: 'var(--color-tier-server-readable)',
              tab: 'data-privacy' as SettingsTabId
            }
          ].map((card) => (
            <button
              key={card.title}
              type="button"
              className="settings-task-card"
              onClick={() => onSelectTab(card.tab)}
            >
              <SettingsIconTile glyph={card.icon} tint={card.tint} size="sm" />
              <span className="settings-task-card-copy">
                <span className="settings-task-card-title">{card.title}</span>
                <span className="settings-task-card-subtitle">{card.subtitle}</span>
              </span>
            </button>
          ))}
        </div>
      </section>
    </div>
  );
}