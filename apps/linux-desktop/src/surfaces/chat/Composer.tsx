import { useId, type KeyboardEvent } from 'react';
import { composerPlaceholder, type ChatBackendId } from './chatTypes.js';

type ComposerProps = {
  backend: ChatBackendId;
  disabled: boolean;
  disabledReason: string;
  streaming: boolean;
  onStop: () => void;
};

export function Composer({ backend, disabled, disabledReason, streaming, onStop }: ComposerProps) {
  const areaId = useId();
  const placeholder = composerPlaceholder(backend);
  const sendDisabled = disabled || streaming;

  return (
    <div className="chat-composer">
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
            onKeyDown={(ev: KeyboardEvent<HTMLTextAreaElement>) => {
              if (ev.key === 'Enter' && !ev.shiftKey) {
                ev.preventDefault();
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
              title={sendDisabled ? 'Send requires live Hermes dispatch on Linux v1' : 'Send message'}
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
              : 'Shift+Enter newline · Send ships with live dispatch'}
        </p>
      </div>
    </div>
  );
}