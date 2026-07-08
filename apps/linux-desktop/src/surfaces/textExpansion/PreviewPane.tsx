import { useId, useMemo, useState } from 'react';
import { expandInAppBuffer, listSnippets } from '../../textExpansionStore.js';

export function PreviewPane({ refreshKey }: { refreshKey: number }) {
  const labelId = useId();
  const resultId = useId();
  const [buffer, setBuffer] = useState('');
  const snippets = useMemo(() => listSnippets(), [refreshKey, buffer]);
  const { output, applied } = useMemo(() => expandInAppBuffer(buffer, snippets), [buffer, snippets]);
  const appliedSnippet = applied ? snippets.find((s) => s.id === applied) : undefined;

  const renderedOutput = useMemo(() => {
    if (!appliedSnippet || output === buffer) {
      return output || '—';
    }
    const body = appliedSnippet.body;
    const idx = output.lastIndexOf(body);
    if (idx < 0) {
      return output;
    }
    return (
      <>
        {output.slice(0, idx)}
        <mark className="te-preview-mark">{body}</mark>
        {output.slice(idx + body.length)}
      </>
    );
  }, [appliedSnippet, buffer, output]);

  return (
    <section className="te-preview" aria-labelledby={labelId}>
      <h3 id={labelId} className="te-preview-title">
        Live expansion preview
      </h3>
      <p className="te-preview-hint muted">Type in the buffer; expansion uses in-app substitution only (onChange).</p>
      <label className="te-preview-label" htmlFor={`${labelId}-input`}>
        Preview buffer
        <textarea
          id={`${labelId}-input`}
          className="te-preview-input"
          rows={3}
          value={buffer}
          onChange={(e) => setBuffer(e.currentTarget.value)}
          placeholder="Type a trigger at the end, e.g. hello ;;sig"
        />
      </label>
      <div className="te-preview-result">
        <span className="te-preview-result-label">Expanded result</span>
        <output id={resultId} className="te-preview-output mono" htmlFor={`${labelId}-input`} aria-live="polite">
          {renderedOutput}
        </output>
      </div>
    </section>
  );
}