import { useCallback, useEffect, useMemo, useState } from 'react';
import type {
  AIInboxConfig,
  AIInboxEgressMode,
  AIInboxRunTelemetry,
  LinuxShellBridge
} from '../../tauriBridge.js';
import { Banner } from '../../components/Banner.js';
import { SettingGroup } from './SettingGroup.js';
import { SettingRow } from './SettingRow.js';

function defaultConfig(): AIInboxConfig {
  return {
    enabled: false,
    egressMode: 'off',
    tickSeconds: 300,
    remotePhaseEveryNTicks: 3,
    dailyBudgetUSD: 1.5,
    maxVerifierCallsPerTick: 3,
    perTickPromptTokenCap: 60_000,
    analystProviderID: 'deepseek',
    analystModel: 'deepseek-v4-flash',
    verifierProviderID: 'openai',
    verifierModel: 'gpt-5.6-luna',
    githubEnabled: true,
    notifyOnP1: true,
    lookbackMinutes: 120,
    founderLensEnabled: true,
    perReplyBudgetUSD: 0.1,
    maxThreadTurns: 40,
    budgetCountsSubscriptionSpend: false
  };
}

function egressExplanation(mode: AIInboxEgressMode): string {
  if (mode === 'off') {
    return 'No conversation text leaves this Linux machine. Deterministic detectors and rule-written briefs still work.';
  }
  if (mode === 'local') {
    return 'Summaries use a model on this machine or local network. Nothing is sent to a cloud model provider.';
  }
  return 'Redacted excerpts may be sent to configured cloud providers. Secrets are scanned and blocked before egress.';
}

function runLabel(run: AIInboxRunTelemetry): string {
  const label = run.gateResult.replaceAll('_', ' ');
  const cost = run.costUSD > 0 ? ` · $${run.costUSD.toFixed(4)}` : ' · no spend';
  return `${label}${cost}`;
}

function ToggleControl({
  checked,
  label,
  disabled,
  onChange
}: {
  checked: boolean;
  label: string;
  disabled: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <label className="setting-toggle">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        aria-label={label}
        onChange={(event) => onChange(event.currentTarget.checked)}
      />
      <span>{checked ? 'On' : 'Off'}</span>
    </label>
  );
}

export function AIInboxSettingsDetail({
  bridge,
  fixtureMode
}: {
  bridge: LinuxShellBridge | null;
  fixtureMode: boolean;
}) {
  const inboxBridge = bridge;
  const [config, setConfig] = useState<AIInboxConfig | null>(fixtureMode ? defaultConfig() : null);
  const [runs, setRuns] = useState<AIInboxRunTelemetry[]>([]);
  const [todaySpendUSD, setTodaySpendUSD] = useState(0);
  const [loading, setLoading] = useState(!fixtureMode);
  const [saving, setSaving] = useState(false);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (fixtureMode) {
      setConfig(defaultConfig());
      setLoading(false);
      setError(null);
      return;
    }
    if (!inboxBridge?.inboxConfigGet) {
      setConfig(null);
      setLoading(false);
      setError('The installed Linux shell does not expose AI Inbox settings yet.');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const [next, telemetry] = await Promise.all([
        inboxBridge.inboxConfigGet(),
        inboxBridge.inboxRunsRecent?.(20)
      ]);
      setConfig(next);
      setRuns(telemetry?.runs ?? []);
      setTodaySpendUSD(telemetry?.todaySpendUSD ?? 0);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not load AI Inbox settings.');
    } finally {
      setLoading(false);
    }
  }, [fixtureMode, inboxBridge]);

  useEffect(() => {
    void load();
  }, [load]);

  const save = useCallback(async (next: AIInboxConfig) => {
    setConfig(next);
    if (fixtureMode) return;
    if (!inboxBridge?.inboxConfigUpdate) {
      setError('The installed Linux shell cannot save AI Inbox settings.');
      return;
    }
    setSaving(true);
    setError(null);
    try {
      // Render daemon truth: it clamps all budget, cadence, and thread limits.
      setConfig(await inboxBridge.inboxConfigUpdate(next));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save AI Inbox settings.');
      await load();
    } finally {
      setSaving(false);
    }
  }, [fixtureMode, inboxBridge, load]);

  const patch = <K extends keyof AIInboxConfig>(key: K, value: AIInboxConfig[K]) => {
    if (!config || saving) return;
    void save({ ...config, [key]: value });
  };

  const analyzeNow = async () => {
    if (fixtureMode || !inboxBridge?.inboxRunNow || running) return;
    setRunning(true);
    setError(null);
    try {
      const result = await inboxBridge.inboxRunNow(true);
      if (!result.accepted) setError(result.reason ?? 'The daemon declined this analysis request.');
      const telemetry = await inboxBridge.inboxRunsRecent(20);
      setRuns(telemetry.runs);
      setTodaySpendUSD(telemetry.todaySpendUSD);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not start an Inbox analysis.');
    } finally {
      setRunning(false);
    }
  };

  const skipSummary = useMemo(() => {
    if (runs.length === 0) return 'No checks recorded yet.';
    const skipped = runs.filter((run) =>
      run.gateResult === 'skipped_unchanged' || run.gateResult === 'skipped_disabled'
    ).length;
    return `${Math.round((skipped / runs.length) * 100)}% of the last ${runs.length} checks found nothing to do.`;
  }, [runs]);

  if (loading) return <p className="muted" role="status">Checking AI Inbox configuration…</p>;
  if (!config) {
    return (
      <Banner tone="degraded" role="alert">
        {error ?? 'AI Inbox settings are unavailable.'}
        <div className="actions">
          <button type="button" className="ghost" onClick={() => void load()}>Retry</button>
        </div>
      </Banner>
    );
  }

  return (
    <>
      {error ? <Banner tone="degraded" role="alert">{error}</Banner> : null}
      <SettingGroup title="AI Inbox" sectionHeader hideTitle>
        <p className="muted settings-tab-lede">
          A background analyst that checks recent sessions and workspaces, names the one next move, and keeps accepted work in the Founder Plan Ledger.
        </p>
        <SettingRow
          iconGlyph="▤"
          label="Run the AI Inbox"
          description="Wakes on the configured cadence. If nothing changed it performs no model call and costs nothing."
          control={
            <ToggleControl
              checked={config.enabled}
              label="Run the AI Inbox"
              disabled={saving}
              onChange={(value) => patch('enabled', value)}
            />
          }
        />
        <SettingRow
          iconGlyph="✦"
          label="Founder Lens"
          description="Uses BurnBar's direct judgment style, enables reply threads, and lets you accept proposed steps into durable plans."
          control={
            <ToggleControl
              checked={config.founderLensEnabled}
              label="Founder Lens"
              disabled={saving}
              onChange={(value) => patch('founderLensEnabled', value)}
            />
          }
        />
      </SettingGroup>

      <SettingGroup title="Privacy & model egress" sectionHeader>
        <SettingRow
          iconGlyph="⛨"
          label="What leaves this machine"
          description={egressExplanation(config.egressMode)}
          control={
            <select
              aria-label="AI Inbox egress mode"
              value={config.egressMode}
              disabled={saving}
              onChange={(event) => patch('egressMode', event.currentTarget.value as AIInboxEgressMode)}
            >
              <option value="off">Nothing</option>
              <option value="local">Local only</option>
              <option value="cloud">Cloud models</option>
            </select>
          }
        />
        <SettingRow
          iconGlyph="⌁"
          label="Check GitHub"
          description="Uses the signed-in gh CLI; OpenBurnBar stores no separate GitHub token."
          control={
            <ToggleControl
              checked={config.githubEnabled}
              label="Check GitHub"
              disabled={saving}
              onChange={(value) => patch('githubEnabled', value)}
            />
          }
        />
        <SettingRow
          iconGlyph="◉"
          label="Urgent notifications"
          description="Notify only for P1 items, rate-limited per condition."
          control={
            <ToggleControl
              checked={config.notifyOnP1}
              label="Urgent AI Inbox notifications"
              disabled={saving}
              onChange={(value) => patch('notifyOnP1', value)}
            />
          }
        />
        <SettingRow
          iconGlyph="⊞"
          label="Phone mirror"
          description="macOS mirrors sealed Inbox items through its Firebase-authenticated app. Linux does not claim this is active until the account/cloud sync plane reports the same encrypted collection contract."
          control={<span className="muted" role="status">Not yet proven</span>}
          readOnlyNote="Local Inbox data remains on this machine; the UI does not pretend cross-device sync is enabled."
        />
      </SettingGroup>

      <SettingGroup title="Budgets & cadence" sectionHeader>
        <SettingRow
          iconGlyph="$"
          label="Daily model budget"
          description={`Spent today: $${todaySpendUSD.toFixed(4)}. Zero disables the cap.`}
          control={
            <label className="settings-verification-value">
              <input
                type="number"
                min={0}
                max={100}
                step={0.25}
                value={config.dailyBudgetUSD}
                disabled={saving}
                aria-label="Daily AI Inbox budget in dollars"
                onChange={(event) => patch('dailyBudgetUSD', Math.max(0, Number(event.currentTarget.value)))}
              />
              <span>USD</span>
            </label>
          }
        />
        <SettingRow
          iconGlyph="↻"
          label="Check every"
          description="Shorter cadence mostly improves freshness; unchanged checks do no model work."
          control={
            <label className="settings-verification-value">
              <input
                type="number"
                min={60}
                max={3_600}
                step={60}
                value={config.tickSeconds}
                disabled={saving}
                aria-label="AI Inbox cadence in seconds"
                onChange={(event) => patch('tickSeconds', Number(event.currentTarget.value))}
              />
              <span>seconds</span>
            </label>
          }
        />
        <SettingRow
          iconGlyph="↥"
          label="Per-reply ceiling"
          description="A Founder Lens reply is refused before egress when its route would exceed this amount."
          control={
            <label className="settings-verification-value">
              <input
                type="number"
                min={0}
                max={5}
                step={0.01}
                value={config.perReplyBudgetUSD}
                disabled={saving}
                aria-label="AI Inbox per reply budget in dollars"
                onChange={(event) => patch('perReplyBudgetUSD', Number(event.currentTarget.value))}
              />
              <span>USD</span>
            </label>
          }
        />
        <SettingRow
          iconGlyph="≡"
          label="Thread prompt window"
          description="Older turns stay visible but fall out of the next model prompt after this limit."
          control={
            <label className="settings-verification-value">
              <input
                type="number"
                min={2}
                max={200}
                step={1}
                value={config.maxThreadTurns}
                disabled={saving}
                aria-label="AI Inbox maximum thread turns"
                onChange={(event) => patch('maxThreadTurns', Number(event.currentTarget.value))}
              />
              <span>turns</span>
            </label>
          }
        />
        <SettingRow
          iconGlyph="◎"
          label="Count subscription spend"
          description="Off counts only real API charges. On also counts imputed value from flat-plan model calls."
          control={
            <ToggleControl
              checked={config.budgetCountsSubscriptionSpend}
              label="Count subscription spend"
              disabled={saving}
              onChange={(value) => patch('budgetCountsSubscriptionSpend', value)}
            />
          }
        />
      </SettingGroup>

      <SettingGroup title="Recent checks" sectionHeader>
        <p className="muted settings-tab-lede">{skipSummary}</p>
        <div className="actions">
          <button
            type="button"
            className="primary"
            disabled={fixtureMode || running || !config.enabled}
            aria-busy={running}
            onClick={() => void analyzeNow()}
          >
            {running ? 'Analyzing…' : 'Analyze now'}
          </button>
          <button type="button" className="ghost" disabled={loading} onClick={() => void load()}>
            Refresh
          </button>
        </div>
        {runs.slice(0, 6).map((run) => (
          <SettingRow
            key={run.tickID}
            iconGlyph={run.gateResult === 'failed' ? '!' : '·'}
            label={new Date(run.startedAt).toLocaleString()}
            description={runLabel(run)}
            control={<span className="muted">{run.itemsNew} new · {run.itemsUpdated} updated</span>}
            readOnlyNote={run.error ?? undefined}
          />
        ))}
      </SettingGroup>
    </>
  );
}
