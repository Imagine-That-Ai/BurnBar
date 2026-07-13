import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Banner } from '../components/Banner.js';
import { PARITY_LEDGER } from '../parityLedger.js';
import {
  configureTextExpansionConsentStorage,
  hydrateTextExpansionConsentStorage,
  readTextExpansionConsent,
  textExpansionConsentError,
  writeTextExpansionConsent
} from '../textExpansionConsent.js';
import {
  expandInAppBuffer,
  findTriggerConflict,
  listSnippets,
  hydrateTextExpansionStorage,
  configureTextExpansionStorageWithPolicy,
  textExpansionStorageError,
  upsertSnippetPersisted,
  deleteSnippetPersisted
} from '../textExpansionStore.js';
import { useShellStore } from '../state/shellStore.js';
import { PreviewPane } from './textExpansion/PreviewPane.js';
import { SnippetImportExport } from './textExpansion/SnippetImportExport.js';
import './textExpansion/textExpansion.css';

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
  const bridge = useShellStore((state) => state.bridge);
  const bridgeReady = useShellStore((state) => state.bridgeReady);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const textExpansionList = bridge?.textExpansionList;
  const textExpansionUpsert = bridge?.textExpansionUpsert;
  const textExpansionDelete = bridge?.textExpansionDelete;
  const textExpansionConsentUpdate = bridge?.textExpansionConsentUpdate;
  const nativeStorageAvailable = Boolean(
    textExpansionList && textExpansionUpsert && textExpansionDelete && textExpansionConsentUpdate
  );
  const nativeUnavailable = bridgeReady && !fixtureMode && !nativeStorageAvailable;
  const consent = readTextExpansionConsent();
  const snippets = useMemo(() => listSnippets(), [version]);
  const editing = editingId ? snippets.find((s) => s.id === editingId) : undefined;
  useEffect(() => {
    const storage = bridge && textExpansionList && textExpansionUpsert && textExpansionDelete && textExpansionConsentUpdate
      ? {
          textExpansionList: textExpansionList.bind(bridge),
          textExpansionUpsert: textExpansionUpsert.bind(bridge),
          textExpansionDelete: textExpansionDelete.bind(bridge),
          textExpansionConsentUpdate: textExpansionConsentUpdate.bind(bridge)
        }
      : null;
    configureTextExpansionStorageWithPolicy(storage, !bridgeReady || fixtureMode);
    configureTextExpansionConsentStorage(storage, !bridgeReady || fixtureMode);
    if (!bridgeReady) return;
    let cancelled = false;
    void Promise.all([
      hydrateTextExpansionStorage(storage),
      hydrateTextExpansionConsentStorage(storage)
    ]).then(() => {
      if (!cancelled) {
        setStorageError(textExpansionStorageError() ?? textExpansionConsentError());
        setVersion((value) => value + 1);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [bridge, bridgeReady, fixtureMode, textExpansionList, textExpansionUpsert, textExpansionDelete, textExpansionConsentUpdate]);
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

  const acknowledge = () => {
    writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
    setVersion((v) => v + 1);
  };

  const consentRow = (
    <label className="consent-row">
      <input
        type="checkbox"
        checked={Boolean(consent?.inAppOnly)}
        onChange={(e) => {
          if (e.currentTarget.checked) acknowledge();
        }}
      />
      {' In-app expansion only (v1). No global key capture on Linux.'}
    </label>
  );

  if (!consent?.inAppOnly) {
    return (
      <>
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
      {nativeUnavailable ? (
        <Banner tone="degraded" role="alert">
          Native text expansion storage is unavailable. In-app snippets are disabled until the packaged shell is repaired.
        </Banner>
      ) : storageError ? <Banner tone="degraded" role="alert">{storageError}</Banner> : null}
      {consentRow}
      <SnippetImportExport disabled={nativeUnavailable} onImported={() => setVersion((v) => v + 1)} />
      <form className="snippet-form" onSubmit={onSubmit} key={editing?.id ?? 'new'}>
        <fieldset disabled={nativeUnavailable}>
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
                disabled={nativeUnavailable}
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
