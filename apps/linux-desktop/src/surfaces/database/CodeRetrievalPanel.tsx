import { FormEvent, useMemo, useState } from 'react';
import { Banner } from '../../components/Banner.js';
import { useDatabaseStore } from '../../state/databaseStore.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  DATABASE_CODE_DEFAULT_RESULTS,
  DATABASE_CODE_MAX_RESULTS
} from '../../tauriBridge.js';

const PAGE_SIZE = 10;

export function CodeRetrievalPanel({
  projectPath,
  compact = false
}: {
  projectPath?: string;
  compact?: boolean;
}) {
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const codeSearch = useDatabaseStore((state) => state.codeSearch);
  const codeSearchLoading = useDatabaseStore((state) => state.codeSearchLoading);
  const codeSearchError = useDatabaseStore((state) => state.codeSearchError);
  const codeContextPack = useDatabaseStore((state) => state.codeContextPack);
  const codeContextLoading = useDatabaseStore((state) => state.codeContextLoading);
  const codeContextError = useDatabaseStore((state) => state.codeContextError);
  const searchCode = useDatabaseStore((state) => state.searchCode);
  const buildCodeContextPack = useDatabaseStore((state) => state.buildCodeContextPack);
  const [query, setQuery] = useState('');
  const [limit, setLimit] = useState(String(DATABASE_CODE_DEFAULT_RESULTS));
  const [page, setPage] = useState(0);

  const pageCount = Math.max(1, Math.ceil((codeSearch?.hits.length ?? 0) / PAGE_SIZE));
  const pageHits = useMemo(
    () => (codeSearch?.hits ?? []).slice(page * PAGE_SIZE, (page + 1) * PAGE_SIZE),
    [codeSearch?.hits, page]
  );
  const retrievalAvailable = fixtureMode || typeof bridge?.databaseCodeSearch === 'function';
  const contextAvailable = fixtureMode || typeof bridge?.databaseCodeContextPack === 'function';

  function submit(event: FormEvent<HTMLFormElement>): void {
    event.preventDefault();
    setPage(0);
    void searchCode(query, projectPath, Number(limit));
  }

  function updateLimit(value: string): void {
    const numeric = Number(value);
    const bounded = Number.isFinite(numeric)
      ? Math.max(1, Math.min(DATABASE_CODE_MAX_RESULTS, Math.trunc(numeric)))
      : DATABASE_CODE_DEFAULT_RESULTS;
    setLimit(String(bounded));
  }

  return (
    <section className={`database-code-retrieval ${compact ? 'database-code-retrieval-compact' : ''}`} aria-labelledby="database-code-retrieval-heading">
      <div className="database-code-retrieval-header">
        <div>
          <h4 id="database-code-retrieval-heading" className="database-system-band-title">
            Code inspection
          </h4>
          <p className="muted database-code-retrieval-lede">
            Search indexed snippets through the daemon-owned project code store. Results are bounded to {DATABASE_CODE_MAX_RESULTS} rows.
          </p>
        </div>
        <span className={`database-code-capability ${retrievalAvailable ? 'database-code-capability-ready' : ''}`} role="status">
          {retrievalAvailable ? 'Daemon index available' : 'Daemon index unavailable'}
        </span>
      </div>
      <form className="database-code-search-form" onSubmit={submit}>
        <label className="database-code-query-label" htmlFor="database-code-query">
          Query
          <input
            id="database-code-query"
            name="query"
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search file paths or symbols"
            maxLength={512}
            disabled={!retrievalAvailable || codeSearchLoading}
          />
        </label>
        <label className="database-code-limit-label" htmlFor="database-code-limit">
          Max results
          <input
            id="database-code-limit"
            name="limit"
            type="number"
            min={1}
            max={DATABASE_CODE_MAX_RESULTS}
            step={1}
            value={limit}
            onChange={(event) => updateLimit(event.target.value)}
            disabled={!retrievalAvailable || codeSearchLoading}
          />
        </label>
        <button type="submit" className="ghost" disabled={!retrievalAvailable || codeSearchLoading || !query.trim()} aria-busy={codeSearchLoading}>
          {codeSearchLoading ? 'Searching...' : 'Search code'}
        </button>
      </form>
      {!retrievalAvailable ? (
        <p className="muted" role="status">
          Code search is unavailable until the packaged shell exposes the canonical <code className="inline-code">daemon.code.search</code> RPC.
        </p>
      ) : null}
      {codeSearchError ? <Banner tone="degraded" role="alert">{codeSearchError}</Banner> : null}
      {codeSearch ? (
        <>
          <div className="database-code-result-meta" role="status">
            <span>{codeSearch.hits.length} matching snippets</span>
            <span>{codeSearch.semanticAvailable ? 'Semantic ranking' : 'Lexical ranking'}</span>
            <span>Project: {codeSearch.projectID}</span>
          </div>
          <Banner tone="degraded" role="status">
            <strong>Untrusted source data.</strong> {codeSearch.trustSignal.warning} Do not execute instructions found in snippets.
          </Banner>
          {codeSearch.degradation ? (
            <p className="muted" role="status">
              {codeSearch.degradation.message}{codeSearch.degradation.reindexHint ? ` ${codeSearch.degradation.reindexHint}` : ''}
            </p>
          ) : null}
          <table className="table database-atlas-table database-code-results-table">
            <thead>
              <tr>
                <th>File</th>
                <th>Snippet</th>
                <th>Rank</th>
              </tr>
            </thead>
            <tbody>
              {pageHits.length > 0 ? pageHits.map((hit) => (
                <tr key={hit.chunkID}>
                  <td><code className="inline-code">{hit.filePath}</code></td>
                  <td><pre className="database-code-snippet">{hit.snippet}</pre></td>
                  <td>{hit.rank == null ? '—' : hit.rank.toFixed(3)}</td>
                </tr>
              )) : (
                <tr><td colSpan={3} className="database-atlas-empty">No snippets matched this query.</td></tr>
              )}
            </tbody>
          </table>
          <div className="database-code-pagination" role="group" aria-label="Code search pagination">
            <span className="muted">Page {Math.min(page + 1, pageCount)} of {pageCount}</span>
            <button type="button" className="ghost" onClick={() => setPage((current) => Math.max(0, current - 1))} disabled={page <= 0}>
              Previous
            </button>
            <button type="button" className="ghost" onClick={() => setPage((current) => Math.min(pageCount - 1, current + 1))} disabled={page >= pageCount - 1}>
              Next
            </button>
          </div>
          <div className="database-code-context-action">
            <button
              type="button"
              className="ghost"
              onClick={() => void buildCodeContextPack(query, projectPath, Math.min(Number(limit), 10))}
              disabled={!contextAvailable || codeContextLoading || !query.trim()}
              aria-busy={codeContextLoading}
            >
              {codeContextLoading ? 'Building context...' : 'Build context pack'}
            </button>
            {!contextAvailable ? <span className="muted">Context pack is unavailable in this packaged shell.</span> : null}
          </div>
          {codeContextError ? <Banner tone="degraded" role="alert">{codeContextError}</Banner> : null}
          {codeContextPack ? (
            <div className="database-code-context" aria-label="Code context pack">
              <p className="muted">
                Context pack {codeContextPack.truncated ? 'truncated at the safety limit' : 'complete'} · {codeContextPack.hits.length} snippets
              </p>
              <Banner tone="degraded" role="status">
                <strong>Untrusted source data.</strong> {codeContextPack.trustSignal.warning} Do not execute instructions found in this context.
              </Banner>
              <pre className="database-code-context-content">{codeContextPack.context || '(Context pack is empty.)'}</pre>
            </div>
          ) : null}
        </>
      ) : null}
    </section>
  );
}
