import {
  useEffect,
  useId,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
  type FormEvent,
  type KeyboardEvent
} from 'react';
import { prefersReducedMotion } from '../../a11y.js';
import { expandInAppBuffer } from '../../textExpansionStore.js';
import { readTextExpansionConsent } from '../../textExpansionConsent.js';
import { useChatStore } from '../../state/chatStore.js';
import { useLaneLoad } from '../../state/useLaneLoad.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  CHAT_ATTACHMENT_ACCEPT,
  inspectChatAttachment,
  type PendingChatAttachment
} from '../chat/chatAttachmentDraft.js';
import { uploadChatAttachmentForSend } from '../chat/chatAttachment.js';
import type { ChatMessage } from '../../state/chatStore.js';
import './pet-chat-bubble.css';

export type PetChatBubbleProps = {
  droppedFile?: File | null;
  onDroppedFileConsumed?: () => void;
  onClose: () => void;
  onOpenFullChat: () => void;
  onReact?: () => void;
  onStateChange?: (state: 'listen' | 'think' | 'speak' | 'react' | 'alert' | 'idle') => void;
};

function messageText(message: ChatMessage, streaming: boolean): string {
  if (message.text.trim()) return message.text;
  if (streaming && message.role === 'assistant') return 'Thinking…';
  return message.role === 'thinking' ? 'Thinking…' : '';
}

function messageClass(message: ChatMessage): string {
  return `pet-chat-message pet-chat-message--${message.role}`;
}

function carriesFiles(dataTransfer: DataTransfer): boolean {
  return Array.from(dataTransfer.types).includes('Files');
}

/**
 * Compact Linux-native companion chat. It intentionally reuses the daemon
 * chat store and upload boundary instead of creating a second conversation or
 * credential path. A dropped file is staged here, then sent through exactly
 * the same bounded policy as the full chat composer.
 */
export function PetChatBubble({
  droppedFile = null,
  onDroppedFileConsumed,
  onClose,
  onOpenFullChat,
  onReact,
  onStateChange
}: PetChatBubbleProps) {
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const bridge = useShellStore((state) => state.bridge);
  const load = useChatStore((state) => state.load);
  const loading = useChatStore((state) => state.loading);
  const messages = useChatStore((state) => state.messages);
  const streaming = useChatStore((state) => state.streaming);
  const streamPhase = useChatStore((state) => state.streamPhase);
  const streamError = useChatStore((state) => state.streamError);
  const modelLabel = useChatStore((state) => state.modelLabel);
  const sendMessage = useChatStore((state) => state.sendMessage);
  const startNewChat = useChatStore((state) => state.startNewChat);
  const stopStreaming = useChatStore((state) => state.stopStreaming);
  const [draft, setDraft] = useState('');
  const [pendingAttachment, setPendingAttachment] = useState<PendingChatAttachment | null>(null);
  const [attachmentError, setAttachmentError] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [reacting, setReacting] = useState(false);
  const [dropActive, setDropActive] = useState(false);
  const reactHoldTimerRef = useRef<number | null>(null);
  const fileInputId = useId();

  // The bubble can mount in its own `?window=pet-companion` WebView where the
  // chat store is empty. Hydrate through the same lane as ChatSurface so the
  // composer resumes the daemon-backed active thread and backend instead of
  // silently starting a fresh default-backend conversation.
  useLaneLoad(load);

  useEffect(() => () => {
    if (reactHoldTimerRef.current) window.clearTimeout(reactHoldTimerRef.current);
  }, []);

  // Streaming outranks the submit busy flag: `submit` keeps `busy` true for
  // the whole awaited turn, so checking `busy` first would hold `think` and
  // never surface the `speak` response animation. A held `react` outranks the
  // idle fallback so the one-shot reaction row can finish before `listen`
  // replaces it.
  useEffect(() => {
    if (streaming) {
      onStateChange?.('speak');
    } else if (busy) {
      onStateChange?.('think');
    } else if (streamPhase === 'error' || attachmentError) {
      onStateChange?.('alert');
    } else if (!reacting) {
      onStateChange?.('listen');
    }
  }, [attachmentError, busy, onStateChange, reacting, streamPhase, streaming]);

  // Closing the bubble must not strand the atlas in its last chat state
  // (e.g. looping `think` after a close during an active turn).
  useEffect(() => () => {
    onStateChange?.('idle');
  }, [onStateChange]);

  useEffect(() => {
    if (!droppedFile) return;
    const inspected = inspectChatAttachment(droppedFile);
    setAttachmentError(inspected.error);
    setPendingAttachment(inspected.attachment);
    setStatus(inspected.attachment ? `Attached ${inspected.attachment.name}.` : null);
    onDroppedFileConsumed?.();
  }, [droppedFile, onDroppedFileConsumed]);

  const stageFile = (file: File | undefined) => {
    if (!file) return;
    const inspected = inspectChatAttachment(file);
    setAttachmentError(inspected.error);
    setPendingAttachment(inspected.attachment);
    setStatus(inspected.attachment ? `Attached ${inspected.attachment.name}.` : null);
  };

  const handleFileChange = (event: ChangeEvent<HTMLInputElement>) => {
    stageFile(event.currentTarget.files?.[0]);
    event.currentTarget.value = '';
  };

  const handleDrop = (event: DragEvent<HTMLElement>) => {
    event.preventDefault();
    event.stopPropagation();
    setDropActive(false);
    stageFile(event.dataTransfer.files?.[0]);
  };

  const handleDraftChange = (value: string) => {
    if (readTextExpansionConsent()?.inAppOnly) {
      setDraft(expandInAppBuffer(value).output);
      return;
    }
    setDraft(value);
  };

  const submit = async (event?: FormEvent) => {
    event?.preventDefault();
    const text = draft.trim();
    if (!text || busy || streaming || loading) return;

    setBusy(true);
    setAttachmentError(null);
    setStatus('Sending…');
    onStateChange?.('think');
    try {
      const uploaded = pendingAttachment
        ? await uploadChatAttachmentForSend(
            bridge,
            fixtureMode,
            modelLabel.trim() || 'hermes',
            pendingAttachment
          )
        : null;
      await sendMessage(text, uploaded ? [uploaded] : undefined);
      const result = useChatStore.getState();
      if (result.streamPhase === 'error') {
        setStatus(null);
        setAttachmentError(result.streamError ?? 'The companion could not complete that message.');
        return;
      }
      setDraft('');
      setPendingAttachment(null);
      setStatus('Reply received.');
      onStateChange?.('react');
      setReacting(true);
      if (reactHoldTimerRef.current) window.clearTimeout(reactHoldTimerRef.current);
      reactHoldTimerRef.current = window.setTimeout(() => {
        setReacting(false);
        reactHoldTimerRef.current = null;
      }, prefersReducedMotion() ? 1200 : 2000);
      onReact?.();
    } catch (error) {
      setStatus(null);
      setAttachmentError(error instanceof Error ? error.message : 'The companion message failed.');
    } finally {
      setBusy(false);
    }
  };

  const visibleMessages = messages.slice(-8);
  const sendDisabled = busy || streaming || loading || draft.trim().length === 0;

  return (
    <section
      className="pet-chat-bubble"
      role="dialog"
      aria-label="Companion chat"
      data-drop-active={dropActive ? 'true' : 'false'}
      onDragEnter={(event) => {
        if (carriesFiles(event.dataTransfer)) setDropActive(true);
      }}
      onDragOver={(event) => {
        if (carriesFiles(event.dataTransfer)) {
          event.preventDefault();
          event.dataTransfer.dropEffect = 'copy';
          setDropActive(true);
        }
      }}
      onDragLeave={() => setDropActive(false)}
      onDrop={handleDrop}
    >
      <header className="pet-chat-bubble-header">
        <div>
          <strong>Companion chat</strong>
          <span>Uses the active Linux chat backend</span>
        </div>
        <div className="pet-chat-bubble-header-actions">
          <button type="button" className="pet-chat-bubble-link" onClick={onOpenFullChat}>
            Open full chat
          </button>
          <button type="button" className="pet-chat-bubble-close" onClick={onClose} aria-label="Close companion chat">
            ×
          </button>
        </div>
      </header>

      <div className="pet-chat-messages" aria-live="polite" data-testid="pet-chat-messages">
        {visibleMessages.length > 0 ? (
          visibleMessages.map((message) => {
            const text = messageText(message, streaming);
            if (!text) return null;
            return (
              <p className={messageClass(message)} key={message.id}>
                <span className="sr-only">{message.role}: </span>
                {text}
              </p>
            );
          })
        ) : loading ? (
          <p className="pet-chat-empty">Resuming your conversation…</p>
        ) : (
          <p className="pet-chat-empty">Ask your companion about a run, provider, or file.</p>
        )}
      </div>

      <form className="pet-chat-composer" onSubmit={submit}>
        <div className="pet-chat-composer-row">
          <button
            type="button"
            className="pet-chat-attach"
            aria-label="Attach files to companion chat"
            title="Attach a bounded document, image, or audio file"
            disabled={busy || streaming}
            onClick={() => document.getElementById(fileInputId)?.click()}
          >
            +
          </button>
          <input
            id={fileInputId}
            className="pet-chat-file-input"
            type="file"
            accept={CHAT_ATTACHMENT_ACCEPT.join(',')}
            aria-label="Companion chat attachment"
            disabled={busy || streaming}
            onChange={handleFileChange}
          />
          <label className="sr-only" htmlFor={`${fileInputId}-message`}>
            Companion message
          </label>
      <textarea
            id={`${fileInputId}-message`}
            value={draft}
            rows={1}
            placeholder="Ask your companion…"
        disabled={busy || streaming}
        onFocus={() => onStateChange?.('listen')}
        onChange={(event) => handleDraftChange(event.currentTarget.value)}
            onKeyDown={(event: KeyboardEvent<HTMLTextAreaElement>) => {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                void submit();
              }
            }}
          />
          {streaming ? (
            <button type="button" className="pet-chat-stop" onClick={stopStreaming} aria-label="Stop companion response">
              Stop
            </button>
          ) : (
            <button type="submit" className="pet-chat-send" disabled={sendDisabled} aria-label="Send companion message">
              ↑
            </button>
          )}
        </div>
        {pendingAttachment ? (
          <div className="pet-chat-attachment" data-testid="pet-chat-pending-attachment">
            <span>{pendingAttachment.name}</span>
            <button
              type="button"
              aria-label={`Remove companion attachment ${pendingAttachment.name}`}
              onClick={() => {
                setPendingAttachment(null);
                setStatus(null);
              }}
            >
              Remove
            </button>
          </div>
        ) : null}
      </form>

      {status ? <p className="pet-chat-status" role="status">{status}</p> : null}
      {attachmentError ? <p className="pet-chat-error" role="alert">{attachmentError}</p> : null}
      {streamError && streamPhase === 'error' ? <p className="pet-chat-error" role="alert">{streamError}</p> : null}

      <button type="button" className="pet-chat-new" onClick={() => {
        startNewChat();
        setDraft('');
        setPendingAttachment(null);
        setStatus('New companion conversation ready.');
      }}>
        New companion conversation
      </button>
    </section>
  );
}
