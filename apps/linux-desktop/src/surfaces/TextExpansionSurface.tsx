import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Banner } from '../components/Banner.js';
import { PARITY_LEDGER } from '../parityLedger.js';
import {
  configureTextExpansionConsentStorage,
  hydrateTextExpansionConsentStorage,
  readTextExpansionConsent,
  textExpansionConsentError,
  writeTextExpansionConsentPersisted
} from '../textExpansionConsent.js';
import {
  expandInAppBuffer,
  findTriggerConflict,
  listSnippets,
  hydrateTextExpansionStorage,
  configureTextExpansionStorageWithPolicy,
  textExpansionNativeStatus,
  textExpansionStorageError,
  hydrateTextExpansionEngineStatus,
  textExpansionEngineError,
  textExpansionEngineStatus,
  startTextExpansionEngine,
  stopTextExpansionEngine,
  upsertSnippetPersisted,
  deleteSnippetPersisted
} from '../textExpansionStore.js';
import { useShellStore } from '../state/shellStore.js';
import { PreviewPane } from './textExpansion/PreviewPane.js';
import { SnippetImportExport } from './textExpansion/SnippetImportExport.js';
import './textExpansion/textExpansion.css';

// The daemon reports `ready` for a live external engine. Keep the legacy
// transitional names accepted for older packaged shells, but never offer a
// second start while the engine is already live.
const ACTIVE_ENGINE_STATES = new Set(['ready', 'running', 'starting', 'stopping']);

function engineIsActive(state: string | undefined): boolean {
  return state !== undefined && ACTIVE_ENGINE_STATES.has(state);
}

/**
 * In-app text expansion (v1). Safety contract: no global key capture on
 * Linux — expansion applies to in-app buffers only, gated behind explicit
 * consent. This file is scanned by the evidence harness for forbidden
 * global-capture APIs; keep all input handling declarative.
 */
export function TextExpansionSurface() {
  const [version, setVersion] = useState(0);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [triggerDraft, setTriggerDraft] = useState('');
  const [storageError, setStorageError] = useState<string | null>(null);
  const [engineBusy, setEngineBusy] = useState(false);
  const [engineActionError, setEngineActionError] = useState<string | null>(null);
  const [consentBusy, setConsentBusy] = useState(false);
  const bridge = useShellStore((state) => state.bridge);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const [storageReady, setStorageReady] = useState(!bridgeReady || fixtureMode);
  const textExpansionList = bridge?.textExpansionList;
  const textExpansionUpsert = bridge?.textExpansionUpsert;
  const textExpansionDelete = bridge?.textExpansionDelete;
  const textExpansionConsentUpdate = bridge?.textExpansionConsentUpdate;
  const textExpansionEngineStatusMethod = bridge?.textExpansionEngineStatus;
  const textExpansionEngineStart = bridge?.textExpansionEngineStart;
  const textExpansionEngineStop = bridge?.textExpansionEngineStop;
  const textExpansionEngineExpand = bridge?.textExpansionEngineExpand;
  const nativeStorageAvailable = Boolean(
    textExpansionList && textExpansionUpsert && textExpansionDelete && textExpansionConsentUpdate
  );
  const nativeEngineAvailable = Boolean(
    textExpansionEngineStatusMethod && textExpansionEngineStart && textExpansionEngineStop
  );
  const nativeUnavailable = bridgeReady && !fixtureMode && !nativeStorageAvailable;
  const consent = readTextExpansionConsent();
  const snippets = useMemo(() => listSnippets(), [version]);
  const nativeStatus = textExpansionNativeStatus();
  const editing = editingId ? snippets.find((s) => s.id === editingId) : undefined;
  useEffect(() => {
    const storage = bridge && textExpansionList && textExpansionUpsert && textExpansionDelete && textExpansionConsentUpdate
      ? {
          textExpansionList: textExpansionList.bind(bridge),
          textExpansionUpsert: textExpansionUpsert.bind(bridge),
          textExpansionDelete: textExpansionDelete.bind(bridge),
          textExpansionConsentUpdate: textExpansionConsentUpdate.bind(bridge),
          ...(textExpansionEngineStatusMethod ? { textExpansionEngineStatus: textExpansionEngineStatusMethod.bind(bridge) } : {}),
          ...(textExpansionEngineStart ? { textExpansionEngineStart: textExpansionEngineStart.bind(bridge) } : {}),
          ...(textExpansionEngineStop ? { textExpansionEngineStop: textExpansionEngineStop.bind(bridge) } : {}),
          ...(textExpansionEngineExpand ? { textExpansionEngineExpand: textExpansionEngineExpand.bind(bridge) } : {})
        }
      : null;
    // Fixture mode keeps its in-memory fixtures across the hydration effect,
    // while still switching a previously fail-closed shell back to fallback
    // policy when the route is mounted.
    configureTextExpansionStorageWithPolicy(storage, !bridgeReady || fixtureMode, fixtureMode);
    configureTextExpansionConsentStorage(storage, !bridgeReady || fixtureMode, fixtureMode);
    setStorageError(null);
    setStorageReady(!bridgeReady || fixtureMode);
    if (!bridgeReady) return;
    let cancelled = false;
    void Promise.all([
      hydrateTextExpansionStorage(storage),
      hydrateTextExpansionConsentStorage(storage)
    ]).then(async () => {
      if (storage && nativeEngineAvailable) await hydrateTextExpansionEngineStatus(storage);
      if (!cancelled) {
        const error = textExpansionStorageError() ?? textExpansionConsentError();
        setStorageError(error);
        setEngineActionError(null);
        setStorageReady(fixtureMode || error == null);
        setVersion((value) => value + 1);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [
    bridge,
    bridgeReady,
    fixtureMode,
    nativeEngineAvailable,
    textExpansionList,
    textExpansionUpsert,
    textExpansionDelete,
    textExpansionConsentUpdate,
    textExpansionEngineStatusMethod,
    textExpansionEngineStart,
    textExpansionEngineStop,
    textExpansionEngineExpand
  ]);
  useEffect(() => {
    setTriggerDraft(editing?.trigger ?? '');
  }, [editing?.id, editing?.trigger]);
  const conflict = useMemo(
    () => findTriggerConflict(triggerDraft, editing?.id),
    [triggerDraft, editing?.id]
  );
  const exactDuplicate = Boolean(
    conflict && triggerDraft.trim() && conflict.trigger === triggerDraft.trim()
  );
  const prefixConflict = Boolean(conflict && !exactDuplicate);

  const acknowledge = (inAppOnly: boolean) => {
    setConsentBusy(true);
    setVersion((v) => v + 1);
    const persist = async () => {
      if (!inAppOnly && nativeEngineAvailable && textExpansionEngineStop) {
        try {
          await stopTextExpansionEngine({ timeoutMillis: 500 });
        } catch (error) {
          // Revocation still proceeds: a failed stop must not leave the
          // renderer believing consent is active or permit a retry loop.
          setStorageError(error instanceof Error ? error.message : 'Could not stop the input-method engine.');
        }
      }
      try {
        await writeTextExpansionConsentPersisted({ inAppOnly, declinedGlobalCapture: true });
        setStorageError(null);
      } catch (error) {
        setStorageError(error instanceof Error ? error.message : textExpansionConsentError() ?? 'Could not save text expansion consent.');
      } finally {
        setConsentBusy(false);
        setVersion((v) => v + 1);
      }
    };
    void persist();
  };

  const persistenceBlocked = Boolean(
    !fixtureMode && bridgeReady && (!storageReady || storageError != null)
  );
  const nativeSetupMessage = nativeUnavailable
    ? 'Native text expansion storage is unavailable. In-app snippets are disabled until the packaged shell is repaired.'
    : storageError
      ? `Native text expansion storage could not be opened: ${storageError}`
      : 'Checking native text expansion storage. Snippet editing will unlock after the daemon responds.';

  const consentRow = (
    <label className="consent-row">
      <input
        type="checkbox"
        checked={Boolean(consent?.inAppOnly)}
        disabled={persistenceBlocked || consentBusy}
        onChange={(e) => {
          acknowledge(e.currentTarget.checked);
        }}
      />
      {' In-app expansion only (v1). No global key capture on Linux.'}
    </label>
  );

  if (!consent?.inAppOnly) {
    return (
      <>
        {persistenceBlocked ? <Banner tone="degraded" role="alert">{nativeSetupMessage}</Banner> : null}
        <Banner tone="degraded" role="alert">
          Acknowledge in-app-only expansion before saving snippets.
        </Banner>
        {consentRow}
      </>
    );
  }

  const onSubmit = (ev: FormEvent<HTMLFormElement>) => {
    ev.preventDefault();
    if (exactDuplicate) return;
    const form = ev.currentTarget;
    const data = new FormData(form);
    void upsertSnippetPersisted({
      id: editing?.id,
      title: String(data.get('title') ?? ''),
      trigger: String(data.get('trigger') ?? ''),
      body: String(data.get('body') ?? ''),
      enabled: data.get('enabled') === 'on'
    }).then(() => {
      setStorageError(null);
      setEditingId(null);
      setTriggerDraft('');
      setVersion((v) => v + 1);
      form.reset();
    }).catch((error) => {
      setStorageError(error instanceof Error ? error.message : textExpansionStorageError() ?? 'Could not save snippet.');
    });
  };

  const probe = expandInAppBuffer(';;probe');
  const ledgerRow = PARITY_LEDGER.find((r) => r.feature.includes('text expansion'));
  const conflictDescId = 'te-trigger-conflict-desc';

  return (
    <>
      {persistenceBlocked ? <Banner tone="degraded" role="alert">{nativeSetupMessage}</Banner> : storageError ? <Banner tone="degraded" role="alert">{storageError}</Banner> : null}
      {!fixtureMode && nativeStatus ? (
        <p className="muted" role="status">
          {nativeStatus.backend
            ? `${nativeStatus.backend} detected for ${nativeStatus.sessionType}; external expansion is ${nativeStatus.supportsExternalExpansion ? 'enabled' : 'not registered'}.`
            : 'No supported Linux input method was detected; in-app expansion remains available.'}
          {' '}{nativeStatus.detail}
        </p>
      ) : null}
      {!fixtureMode && nativeEngineAvailable ? (
        <section aria-labelledby="te-engine-title">
          <h3 id="te-engine-title">Input-method engine</h3>
          {(engineActionError ?? textExpansionEngineError()) ? (
            <Banner tone="degraded" role="alert">
              <span>{`Input-method status unavailable: ${engineActionError ?? textExpansionEngineError()}`}</span>{' '}
              <button
                type="button"
                className="ghost"
                disabled={engineBusy || persistenceBlocked}
                onClick={() => {
                  setEngineActionError(null);
                  setEngineBusy(true);
                  void hydrateTextExpansionEngineStatus().finally(() => {
                    setEngineBusy(false);
                    setVersion((v) => v + 1);
                  });
                }}
              >
                Retry status
              </button>
            </Banner>
          ) : null}
          {textExpansionEngineStatus() ? (
            <p className="muted" role="status">
              {`Engine ${textExpansionEngineStatus()?.state ?? 'unknown'} — ${textExpansionEngineStatus()?.detail ?? 'No status detail.'}`}
            </p>
          ) : !engineActionError && !textExpansionEngineError() ? (
            <p className="muted" role="status">Checking input-method engine status.</p>
          ) : null}
          <button
            type="button"
            className="ghost"
            disabled={engineBusy || persistenceBlocked || consentBusy}
            onClick={() => {
              const running = engineIsActive(textExpansionEngineStatus()?.state);
              setEngineActionError(null);
              setEngineBusy(true);
              void (running ? stopTextExpansionEngine({ timeoutMillis: 500 }) : startTextExpansionEngine({ timeoutMillis: 1_000 }))
                .catch((error) => {
                  setEngineActionError(error instanceof Error ? error.message : 'Input-method engine transition failed.');
                })
                .finally(() => {
                  setEngineBusy(false);
                  setVersion((v) => v + 1);
                });
            }}
          >
            {engineIsActive(textExpansionEngineStatus()?.state)
              ? 'Stop input-method engine'
              : 'Start input-method engine'}
          </button>
        </section>
      ) : !fixtureMode && nativeStorageAvailable ? (
        <p className="muted" role="status">
          Input-method engine controls are unavailable in this packaged shell. In-app expansion remains available.
        </p>
      ) : null}
      {consentRow}
      <SnippetImportExport disabled={persistenceBlocked} onImported={() => setVersion((v) => v + 1)} />
      <form className="snippet-form" onSubmit={onSubmit} key={editing?.id ?? 'new'}>
        <fieldset disabled={persistenceBlocked}>
        <label>
          Title
          <input type="text" name="title" placeholder="Title" required defaultValue={editing?.title ?? ''} />
        </label>
        <label>
          Trigger
          <input
            type="text"
            name="trigger"
            className="mono"
            placeholder="Trigger e.g. ;;sig"
            required
            defaultValue={editing?.trigger ?? ''}
            aria-describedby={conflict ? conflictDescId : undefined}
            onChange={(e) => setTriggerDraft(e.currentTarget.value)}
          />
          <p className="te-trigger-hint muted">
            Use a unique suffix pattern (e.g. <span className="mono">;;sig</span>). Matches the end of the in-app
            buffer only.
          </p>
        </label>
        {exactDuplicate ? (
          <Banner tone="degraded" role="alert">
            An enabled snippet already uses this trigger. Change the trigger before saving.
          </Banner>
        ) : null}
        {prefixConflict && conflict ? (
          <Banner tone="degraded" role="alert">
            <p id={conflictDescId} className="te-conflict-desc">
              {`Trigger overlaps enabled snippet “${conflict.trigger}” (${conflict.title}). Saving is allowed, but expansion order may surprise you.`}
            </p>
          </Banner>
        ) : null}
        <label>
          Body
          <textarea name="body" rows={3} placeholder="Expansion body" defaultValue={editing?.body ?? ''} />
        </label>
        <label>
          <input type="checkbox" name="enabled" defaultChecked={editing ? editing.enabled : true} /> Enabled
        </label>
        <button className="primary" type="submit" disabled={exactDuplicate}>
          {editing ? 'Update snippet' : 'Add snippet'}
        </button>
        </fieldset>
      </form>
      {snippets.length === 0 ? (
        <p className="muted te-empty-list">No snippets yet. Add one above or import JSON.</p>
      ) : (
        <ul className="snippet-list">
          {snippets.map((s) => (
            <li key={s.id} className={s.enabled ? undefined : 'snippet-disabled'}>
              <strong className="mono">{s.trigger}</strong>
              {` — ${s.title}`}
              {s.enabled ? '' : ' (disabled)'}
              <button
                type="button"
                className="ghost"
                disabled={persistenceBlocked}
                onClick={() => {
                  setEditingId(s.id);
                  setTriggerDraft(s.trigger);
                }}
              >
                Edit
              </button>
              <button
                type="button"
                className="ghost"
                disabled={persistenceBlocked}
                onClick={() => {
                  void deleteSnippetPersisted(s.id).then(() => {
                    if (editingId === s.id) {
                      setEditingId(null);
                      setTriggerDraft('');
                    }
                    setStorageError(null);
                    setVersion((v) => v + 1);
                  }).catch((error) => {
                    setStorageError(error instanceof Error ? error.message : textExpansionStorageError() ?? 'Could not delete snippet.');
                  });
                }}
              >
                Delete
              </button>
            </li>
          ))}
        </ul>
      )}
      <PreviewPane refreshKey={version} />
      <p className="muted">{`Live buffer probe → ${probe.output}`}</p>
      {ledgerRow?.substitution ? <p className="muted">{ledgerRow.substitution}</p> : null}
    </>
  );
}
