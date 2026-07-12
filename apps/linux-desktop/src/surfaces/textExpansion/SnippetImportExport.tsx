import { useId, useRef, useState, type ChangeEvent } from 'react';
import { Banner } from '../../components/Banner.js';
import { exportSnippets, importSnippets } from '../../textExpansionStore.js';

export function SnippetImportExport({ onImported }: { onImported: () => void }) {
  const fileInputId = useId();
  const fileRef = useRef<HTMLInputElement>(null);
  const [status, setStatus] = useState<{ tone: 'ok' | 'degraded'; message: string } | null>(null);

  const onExport = () => {
    const json = exportSnippets();
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = 'openburnbar-text-expansion-snippets.json';
    anchor.click();
    URL.revokeObjectURL(url);
    setStatus({ tone: 'ok', message: 'Exported snippets as JSON.' });
  };

  const onFileChange = (ev: ChangeEvent<HTMLInputElement>) => {
    const file = ev.currentTarget.files?.[0];
    ev.currentTarget.value = '';
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        const text = String(reader.result ?? '');
        const result = importSnippets(text);
        onImported();
        setStatus({
          tone: 'ok',
          message: `Import complete: ${result.added} added, ${result.skipped} skipped.`
        });
      } catch (e) {
        setStatus({
          tone: 'degraded',
          message: e instanceof Error ? e.message : 'Import failed.'
        });
      }
    };
    reader.onerror = () => {
      setStatus({ tone: 'degraded', message: 'Could not read import file.' });
    };
    reader.readAsText(file);
  };

  return (
    <section className="te-import-export" aria-label="Snippet import and export">
      <div className="te-import-export-actions">
        <button type="button" className="ghost" onClick={onExport}>
          Export JSON
        </button>
        <button type="button" className="ghost" onClick={() => fileRef.current?.click()}>
          Import JSON
        </button>
        <input
          ref={fileRef}
          id={fileInputId}
          type="file"
          accept="application/json,.json"
          className="te-import-file"
          onChange={onFileChange}
          tabIndex={-1}
          aria-hidden
        />
      </div>
      {status ? (
        <Banner tone={status.tone} role={status.tone === 'degraded' ? 'alert' : 'status'}>
          {status.message}
        </Banner>
      ) : null}
    </section>
  );
}