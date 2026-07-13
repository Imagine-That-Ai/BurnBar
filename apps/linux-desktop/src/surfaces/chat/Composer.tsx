import { useId, useRef, useState, type ChangeEvent, type FormEvent, type KeyboardEvent } from 'react';
import { readTextExpansionConsent } from '../../textExpansionConsent.js';
import { expandInAppBuffer } from '../../textExpansionStore.js';
import { composerPlaceholder, type ChatBackendId } from './chatTypes.js';

export const MAX_CHAT_ATTACHMENT_BYTES = 10 * 1024 * 1024;
export const CHAT_ATTACHMENT_ACCEPT = [
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
  'application/pdf'
] as const;
const CHAT_ATTACHMENT_EXTENSIONS = new Set(['.txt', '.md', '.markdown', '.csv', '.json', '.pdf']);

export type PendingChatAttachment = {
  name: string;
  size: number;
  type: string;
  lastModified: number;
};

type ComposerProps = {
  backend: ChatBackendId;
  disabled: boolean;
  disabledReason: string;
  streaming: boolean;
  /** True while a send is still composing (persist + gateway probe) before
   * streaming starts. Blocks submits so an Enter in that window cannot clear
   * the draft while the store's composing guard silently drops the text. */
  busy: boolean;
  /** Secure/password-like fields must never run text expansion. */
  secureField?: boolean;
  onSend: (text: string) => void;
  onStop: () => void;
};

export function Composer({
  backend,
  disabled,
  disabledReason,
  streaming,
  busy,
  secureField = false,
  onSend,
  onStop
}: ComposerProps) {
  const areaId = useId();
  const fileInputId = useId();
  const fileInputRef = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState('');
  const [pendingAttachment, setPendingAttachment] = useState<PendingChatAttachment | null>(null);
  const [attachmentError, setAttachmentError] = useState<string | null>(null);
  const placeholder = composerPlaceholder(backend);
  const sendDisabled =
    disabled || streaming || busy || draft.trim().length === 0 || pendingAttachment !== null;

  const inspectAttachment = (file: File): PendingChatAttachment | null => {
    if (file.size > MAX_CHAT_ATTACHMENT_BYTES) {
      setAttachmentError('Attachment exceeds the 10 MB limit.');
      return null;
    }
    const type = file.type.trim().toLowerCase();
    const extension = file.name.slice(file.name.lastIndexOf('.')).toLowerCase();
    if (!CHAT_ATTACHMENT_ACCEPT.includes(type as (typeof CHAT_ATTACHMENT_ACCEPT)[number]) && !CHAT_ATTACHMENT_EXTENSIONS.has(extension)) {
      setAttachmentError('Unsupported attachment type. Choose text, JSON, CSV, Markdown, or PDF.');
      return null;
    }
    setAttachmentError(null);
    return {
      name: file.name,
      size: file.size,
      type: type || 'application/octet-stream',
      lastModified: file.lastModified
    };
  };

  const handleAttachmentChange = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.currentTarget.files?.[0];
    event.currentTarget.value = '';
    if (!file) return;
    setPendingAttachment(inspectAttachment(file));
  };

  const removeAttachment = () => {
    setPendingAttachment(null);
    setAttachmentError(null);
  };

  const handleDraftChange = (value: string) => {
    if (!secureField && readTextExpansionConsent()?.inAppOnly) {
      setDraft(expandInAppBuffer(value).output);
      return;
    }
    setDraft(value);
  };

  const submit = (ev?: FormEvent) => {
    ev?.preventDefault();
    const message = draft.trim();
    if (!message || disabled || streaming || busy || pendingAttachment) return;
    setDraft('');
    onSend(message);
  };

  return (
    <form className="chat-composer" data-backend={backend} onSubmit={submit}>
      <div className="chat-composer-inner">
        <div className="chat-composer-row chat-composer-input-row">
          <button
            type="button"
            className="ghost chat-composer-attach"
            disabled={disabled}
            title="Attach file metadata (sending is unavailable)"
            aria-label="Attach files"
            onClick={() => fileInputRef.current?.click()}
          >
            <span aria-hidden="true">+</span>
          </button>
          <input
            ref={fileInputRef}
            id={fileInputId}
            className="chat-composer-file-input"
            type="file"
            accept={CHAT_ATTACHMENT_ACCEPT.join(',')}
            disabled={disabled}
            aria-label="Attachment file"
            onChange={handleAttachmentChange}
          />
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
            onChange={(ev) => handleDraftChange(ev.currentTarget.value)}
            onKeyDown={(ev: KeyboardEvent<HTMLTextAreaElement>) => {
              if (ev.key === 'Enter' && !ev.shiftKey) {
                ev.preventDefault();
                submit();
              }
            }}
          />
          <div className="chat-composer-send-cluster">
            {streaming ? (
              <button
                type="button"
                className="chat-composer-stop"
                onClick={onStop}
                aria-label="Stop generating"
              >
                Stop
              </button>
            ) : null}
            <button
              type="button"
              className="chat-composer-send"
              disabled={sendDisabled}
              aria-label="Send message"
              title={
                sendDisabled
                  ? disabledReason ||
                    (pendingAttachment
                      ? 'Remove the attachment; attachment transport is unavailable.'
                      : busy
                        ? 'Sending…'
                        : 'Enter a message before sending')
                  : 'Send message'
              }
              onClick={() => submit()}
            >
              <span aria-hidden="true">↑</span>
            </button>
          </div>
        </div>
        {pendingAttachment ? (
          <div className="chat-pending-attachment" data-testid="pending-attachment">
            <span className="chat-pending-attachment-meta">
              <strong>{pendingAttachment.name}</strong>
              <span>
                {(pendingAttachment.size / 1024).toFixed(1)} KB · {pendingAttachment.type}
              </span>
            </span>
            <button
              type="button"
              className="ghost chat-pending-attachment-remove"
              onClick={removeAttachment}
              aria-label={`Remove attachment ${pendingAttachment.name}`}
              title="Remove attachment"
            >
              ×
            </button>
          </div>
        ) : null}
        {attachmentError ? (
          <p className="chat-composer-attachment-error" role="alert">
            {attachmentError}
          </p>
        ) : null}
        <p className="chat-composer-hint muted">
          {pendingAttachment
            ? 'Attachment is staged as metadata only. Remove it to send; transport is unavailable.'
            : disabled && disabledReason
            ? disabledReason
            : streaming
              ? 'Streaming in progress — Stop cancels the active turn.'
              : busy
                ? 'Sending…'
                : 'Shift+Enter newline'}
        </p>
      </div>
    </form>
  );
}
