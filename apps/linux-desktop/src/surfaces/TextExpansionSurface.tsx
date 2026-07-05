import { useMemo, useState, type FormEvent } from 'react';
import { Banner } from '../components/Banner.js';
import { PARITY_LEDGER } from '../parityLedger.js';
import { readTextExpansionConsent, writeTextExpansionConsent } from '../textExpansionConsent.js';
import {
  deleteSnippet,
  expandInAppBuffer,
  listSnippets,
  upsertSnippet
} from '../textExpansionStore.js';

/**
 * In-app text expansion (v1). Safety contract: no global key capture on
 * Linux — expansion applies to in-app buffers only, gated behind explicit
 * consent. This file is scanned by the evidence harness for forbidden
 * global-capture APIs; keep all input handling declarative.
 */
export function TextExpansionSurface() {
  const [version, setVersion] = useState(0);
  const [editingId, setEditingId] = useState<string | null>(null);
  const consent = readTextExpansionConsent();
  const snippets = useMemo(() => listSnippets(), [version]);
  const editing = editingId ? snippets.find((s) => s.id === editingId) : undefined;

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
    const form = ev.currentTarget;
    const data = new FormData(form);
    upsertSnippet({
      id: editing?.id,
      title: String(data.get('title') ?? ''),
      trigger: String(data.get('trigger') ?? ''),
      body: String(data.get('body') ?? ''),
      enabled: data.get('enabled') === 'on'
    });
    setEditingId(null);
    setVersion((v) => v + 1);
    form.reset();
  };

  const probe = expandInAppBuffer(';;probe');
  const ledgerRow = PARITY_LEDGER.find((r) => r.feature.includes('text expansion'));

  return (
    <>
      {consentRow}
      <form className="snippet-form" onSubmit={onSubmit} key={editing?.id ?? 'new'}>
        <label>
          Title
          <input type="text" name="title" placeholder="Title" required defaultValue={editing?.title ?? ''} />
        </label>
        <label>
          Trigger
          <input
            type="text"
            name="trigger"
            placeholder="Trigger e.g. ;;sig"
            required
            defaultValue={editing?.trigger ?? ''}
          />
        </label>
        <label>
          Body
          <textarea name="body" rows={3} placeholder="Expansion body" defaultValue={editing?.body ?? ''} />
        </label>
        <label>
          <input type="checkbox" name="enabled" defaultChecked={editing ? editing.enabled : true} /> Enabled
        </label>
        <button className="primary" type="submit">
          {editing ? 'Update snippet' : 'Add snippet'}
        </button>
      </form>
      <ul className="snippet-list">
        {snippets.map((s) => (
          <li key={s.id}>
            <strong>{s.trigger}</strong>
            {` — ${s.title}`}
            {s.enabled ? '' : ' (disabled)'}
            <button type="button" className="ghost" onClick={() => setEditingId(s.id)}>
              Edit
            </button>
            <button
              type="button"
              className="ghost"
              onClick={() => {
                deleteSnippet(s.id);
                if (editingId === s.id) setEditingId(null);
                setVersion((v) => v + 1);
              }}
            >
              Delete
            </button>
          </li>
        ))}
      </ul>
      <p className="muted">{`Live buffer probe → ${probe.output}`}</p>
      {ledgerRow?.substitution ? <p className="muted">{ledgerRow.substitution}</p> : null}
    </>
  );
}
