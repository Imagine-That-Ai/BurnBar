import { useId, useState, type FormEvent, type KeyboardEvent } from 'react';
import { composerPlaceholder, type ChatBackendId } from './chatTypes.js';

type ComposerProps = {
  backend: ChatBackendId;
  disabled: boolean;
  disabledReason: string;
  streaming: boolean;
  onSend: (text: string) => void;
  onStop: () => void;
};

export function Composer({ backend, disabled, disabledReason, streaming, onSend, onStop }: ComposerProps) {
  const areaId = useId();
  const [draft, setDraft] = useState('');
  const placeholder = composerPlaceholder(backend);
  const sendDisabled = disabled || streaming || draft.trim().length === 0;

  const submit = (ev?: FormEvent) => {
    ev?.preventDefault();
    const message = draft.trim();
    if (!message || disabled || streaming) return;
    setDraft('');
    onSend(message);
  };

  return (
    <form className="chat-composer" onSubmit={submit}>
      <div className="chat-composer-inner">
        <div className="chat-composer-row chat-composer-input-row">
          <button
            type="button"
            className="ghost chat-composer-attach"
            disabled={disabled}
            title="Attach files (live dispatch)"
            aria-label="Attach files"
          >
            <span aria-hidden="true">+</span>
          </button>
          <label className="sr-only" htmlFor={areaId}>
            Message composer
          </label>
          <textarea
            id={areaId}
            className="chat-composer-field"
            disabled={disabled}
            placeholder={placeholder}
            rows={1}
            value={draft}
            onChange={(ev) => setDraft(ev.currentTarget.value)}
            onKeyDown={(ev: KeyboardEvent<HTMLTextAreaElement>) => {
              if (ev.key === 'Enter' && !ev.shiftKey) {
                ev.preventDefault();
                submit();
              }
            }}
          />
          <div className="chat-composer-send-cluster">
            {streaming ? (
              <button type="button" className="chat-composer-stop" onClick={onStop} aria-label="Stop generating">
                Stop
              </button>
            ) : null}
            <button
              type="button"
              className="chat-composer-send"
              disabled={sendDisabled}
              aria-label="Send message"
              title={sendDisabled ? disabledReason || 'Enter a message before sending' : 'Send message'}
              onClick={() => submit()}
            >
              <span aria-hidden="true">↑</span>
            </button>
          </div>
        </div>
        <p className="chat-composer-hint muted">
          {disabled && disabledReason
            ? disabledReason
            : streaming
              ? 'Streaming in progress — Stop cancels the active turn.'
              : 'Shift+Enter newline'}
        </p>
      </div>
    </form>
  );
}
