import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react';
import type { SessionEntry } from '../../tauriBridge.js';
import { formatThreadActivity, threadMessageCount, threadPreview } from './chatTypes.js';

const DEBOUNCE_MS = 300;

type ThreadRailProps = {
  threads: SessionEntry[];
  selectedId: string | null;
  loading: boolean;
  query: string;
  hasMore: boolean;
  onSelect: (id: string) => void;
  onSearch: (query: string) => void;
  onLoadMore: () => void;
  onNewChat: () => void;
};

export function ThreadRail({
  threads,
  selectedId,
  loading,
  query,
  hasMore,
  onSelect,
  onSearch,
  onLoadMore,
  onNewChat
}: ThreadRailProps) {
  const searchId = useId();
  const [local, setLocal] = useState(query);
  const timerRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    setLocal(query);
  }, [query]);

  useEffect(() => {
    return () => clearTimeout(timerRef.current);
  }, []);

  const scheduleSearch = (value: string) => {
    clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => onSearch(value), DEBOUNCE_MS);
  };

  const onKeyDown = (ev: KeyboardEvent<HTMLInputElement>) => {
    if (ev.key === 'Escape') {
      setLocal('');
      onSearch('');
    }
  };

  return (
    <aside className="chat-rail" aria-label="Conversation threads">
      <div className="chat-rail-header">
        <button type="button" className="chat-new-button" onClick={onNewChat}>
          New chat
        </button>
      </div>
      <div className="chat-thread-search">
        <label className="sr-only" htmlFor={searchId}>
          Search chats
        </label>
        <input
          id={searchId}
          type="search"
          role="searchbox"
          placeholder="Search chats"
          value={local}
          onChange={(e) => {
            setLocal(e.target.value);
            scheduleSearch(e.target.value);
          }}
          onKeyDown={onKeyDown}
          autoComplete="off"
        />
      </div>
      <ul
        className={loading && threads.length === 0 ? 'chat-thread-list chat-skeleton-rail' : 'chat-thread-list'}
        aria-busy={loading && threads.length === 0}
      >
        {loading && threads.length === 0
          ? Array.from({ length: 6 }, (_, i) => (
              <li key={`sk-${i}`}>
                <div className="chat-thread-row" aria-hidden="true" />
              </li>
            ))
          : threads.map((t) => (
              <li key={t.id}>
                <button
                  type="button"
                  className={selectedId === t.id ? 'chat-thread-row is-selected' : 'chat-thread-row'}
                  onClick={() => onSelect(t.id)}
                  aria-current={selectedId === t.id ? 'true' : undefined}
                >
                  <span className="chat-thread-row-head">
                    <span className="chat-thread-row-title">{t.title}</span>
                    {selectedId === t.id ? (
                      <span className="chat-thread-row-check" aria-hidden="true">
                        ✓
                      </span>
                    ) : null}
                  </span>
                  <span className="chat-thread-row-snippet">{threadPreview(t)}</span>
                  <span className="chat-thread-row-meta">
                    {threadMessageCount(t)} msgs · {formatThreadActivity(t.startedAt)}
                  </span>
                </button>
              </li>
            ))}
      </ul>
      {hasMore ? (
        <div className="chat-rail-footer">
          <button type="button" className="ghost" onClick={onLoadMore}>
            Load more
          </button>
        </div>
      ) : null}
    </aside>
  );
}