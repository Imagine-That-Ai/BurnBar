import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import { useActivityStore } from '../../state/activityStore.js';

const DEBOUNCE_MS = 300;

export function SearchBox() {
  const labelId = useId();
  const inputId = useId();
  const storeQuery = useActivityStore((s) => s.query);
  const search = useActivityStore((s) => s.search);
  const [local, setLocal] = useState(storeQuery);
  const timerRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    setLocal(storeQuery);
  }, [storeQuery]);

  useEffect(() => {
    return () => {
      clearTimeout(timerRef.current);
    };
  }, []);

  const scheduleSearch = (value: string) => {
    clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => {
      void search(value);
    }, DEBOUNCE_MS);
  };

  const onChange = (value: string) => {
    setLocal(value);
    scheduleSearch(value);
  };

  const clearQuery = () => {
    clearTimeout(timerRef.current);
    setLocal('');
    void search('');
  };

  const onKeyDown = (ev: KeyboardEvent<HTMLInputElement>) => {
    if (ev.key !== 'Escape') return;
    ev.preventDefault();
    clearQuery();
  };

  return (
    <div className="activity-search">
      <label id={labelId} htmlFor={inputId} className="activity-search-label">
        Search sessions
      </label>
      <div className="activity-search-field">
        <input
          id={inputId}
          type="search"
          className="activity-search-input"
          value={local}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={onKeyDown}
          aria-labelledby={labelId}
          placeholder="Title, provider, or model"
          autoComplete="off"
        />
        {local ? (
          <button
            type="button"
            className="activity-search-clear"
            aria-label="Clear search"
            onClick={clearQuery}
          >
            ×
          </button>
        ) : null}
      </div>
    </div>
  );
}