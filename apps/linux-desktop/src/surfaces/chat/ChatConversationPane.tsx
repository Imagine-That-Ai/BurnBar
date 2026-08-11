import { useEffect, useRef, useState, type DragEvent } from 'react';
import type { ChatControllerStore } from '../../state/chatStore.js';
import type { ChatWorkspaceColorToken } from '../../state/chatWorkspacePersistence.js';
import { useShellStore } from '../../state/shellStore.js';
import {
  canOpenChatCitation,
  normalizeMemoryCitations,
  type MemoryCitation
} from './chatTypes.js';
import { uploadChatAttachmentForSend } from './chatAttachment.js';
import type { PendingChatAttachment } from './Composer.js';
import { Composer } from './Composer.js';
import { MessageStream } from './MessageStream.js';
import { BackendStrip } from './BackendStrip.js';

export type ChatConversationPaneProps = {
  paneID: string;
  controller: ChatControllerStore;
  active: boolean;
  showsChrome: boolean;
  zoomed: boolean;
  title: string | null;
  colorToken: ChatWorkspaceColorToken | null;
  alertsEnabled: boolean;
  unseen: boolean;
  otherTabs: Array<{ id: string; title: string }>;
  onActivate: () => void;
  onSplitHorizontal: () => void;
  onSplitVertical: () => void;
  onClose: () => void;
  onToggleZoom: () => void;
  onRename: (title: string | null) => void;
  onColorChange: (color: ChatWorkspaceColorToken | null) => void;
  onAlertsChange: (enabled: boolean) => void;
  onMoveToNewTab: () => void;
  onMoveToTab: (tabID: string) => void;
  onMarkSeen: () => void;
  onPaneDragStart: (event: DragEvent<HTMLElement>) => void;
};

const COLOR_OPTIONS: Array<{ id: ChatWorkspaceColorToken; label: string }> = [
  { id: 'whimsy', label: 'Whimsy' },
  { id: 'aureate', label: 'Aureate' },
  { id: 'ember', label: 'Ember' },
  { id: 'amber', label: 'Amber' },
  { id: 'success', label: 'Success' },
  { id: 'frost', label: 'Frost' }
];

export function ChatConversationPane({
  paneID,
  controller,
  active,
  showsChrome,
  zoomed,
  title,
  colorToken,
  alertsEnabled,
  unseen,
  otherTabs,
  onActivate,
  onSplitHorizontal,
  onSplitVertical,
  onClose,
  onToggleZoom,
  onRename,
  onColorChange,
  onAlertsChange,
  onMoveToNewTab,
  onMoveToTab,
  onMarkSeen,
  onPaneDragStart
}: ChatConversationPaneProps) {
  const bridge = useShellStore((state) => state.bridge);
  const fixtureMode = useShellStore((state) => state.fixtureMode);
  const setRoute = useShellStore((state) => state.setRoute);
  const threads = controller((state) => state.threads);
  const selectedThreadId = controller((state) => state.selectedThreadId);
  const messages = controller((state) => state.messages);
  const messagesLoading = controller((state) => state.messagesLoading);
  const hasMoreMessages = controller((state) => state.hasMoreMessages);
  const loadingOlderMessages = controller((state) => state.loadingOlderMessages);
  const loadingAllMessages = controller((state) => state.loadingAllMessages);
  const historyError = controller((state) => state.historyError);
  const config = controller((state) => state.config);
  const catalog = controller((state) => state.catalog);
  const backend = controller((state) => state.backend);
  const modelLabel = controller((state) => state.modelLabel);
  const modelOptionID = controller((state) => state.modelOptionID);
  const thinkingLevel = controller((state) => state.thinkingLevel);
  const streaming = controller((state) => state.streaming);
  const streamPhase = controller((state) => state.streamPhase);
  const streamError = controller((state) => state.streamError);
  const gatewayStatus = controller((state) => state.gatewayStatus);
  const warnings = controller((state) => state.warnings);
  const sharedFeaturesAvailable = controller((state) => state.sharedFeaturesAvailable);
  const rootRef = useRef<HTMLDivElement>(null);
  const [citationStatus, setCitationStatus] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState(title ?? '');
  const selectedThread = threads.find((thread) => thread.id === selectedThreadId) ?? null;
  const hasActiveTranscript = Boolean(selectedThread) || messages.length > 0 || streaming;
  const composerDisabled = !fixtureMode && gatewayStatus !== 'reachable';
  const composerDisabledReason =
    gatewayStatus === 'disabled'
      ? 'Gateway chat is disabled in daemon health.'
      : gatewayStatus === 'unreachable'
        ? 'Gateway health check failed.'
        : gatewayStatus === 'unknown'
          ? 'Checking gateway health…'
          : '';

  useEffect(() => {
    setRenameDraft(title ?? '');
  }, [title]);

  useEffect(() => {
    if (active && unseen) onMarkSeen();
  }, [active, onMarkSeen, unseen]);

  const sendComposerMessage = async (
    text: string,
    attachment?: PendingChatAttachment
  ): Promise<boolean> => {
    if (attachment) {
      const uploaded = await uploadChatAttachmentForSend(
        bridge,
        fixtureMode,
        controller.getState().modelLabel.trim() || 'hermes',
        attachment
      );
      await controller.getState().sendMessage(text, [uploaded]);
    } else {
      await controller.getState().sendMessage(text);
    }
    return controller.getState().streamPhase === 'done';
  };

  const openCitation = async (citation: MemoryCitation) => {
    const normalized = normalizeMemoryCitations([citation])[0];
    const availableThreadIDs = controller.getState().threads.map((thread) => thread.id);
    const currentThreadID = controller.getState().selectedThreadId;
    if (!normalized || !canOpenChatCitation(normalized, currentThreadID, availableThreadIDs)) return;
    const targetThreadID = normalized.threadID ?? currentThreadID;
    const targetMessageID = normalized.messageId;
    if (!targetThreadID || !targetMessageID || controller.getState().streaming) return;
    setCitationStatus('Opening cited source message…');
    if (targetThreadID !== currentThreadID) {
      await controller.getState().selectThread(targetThreadID);
    }
    if (controller.getState().selectedThreadId !== targetThreadID) {
      setCitationStatus('Cited source is no longer available.');
      return;
    }
    const exists = controller
      .getState()
      .messages.some((message) => message.id === targetMessageID && message.threadID === targetThreadID);
    if (!exists) {
      setCitationStatus('Loading cited source message from the daemon…');
      const loaded = await controller.getState().loadUntilMessage(targetMessageID, targetThreadID);
      if (!loaded) {
        setCitationStatus('Cited source is no longer available.');
        return;
      }
    }
    setCitationStatus('Cited source message opened.');
    const element = Array.from(
      rootRef.current?.querySelectorAll<HTMLElement>('[data-chat-message-id]') ?? []
    ).find((candidate) => candidate.dataset.chatMessageId === targetMessageID);
    element?.scrollIntoView?.({ block: 'center', behavior: 'smooth' });
    element?.focus?.({ preventScroll: true });
  };

  return (
    <div
      ref={rootRef}
      className={[
        'chat-pane',
        active ? 'is-active' : '',
        zoomed ? 'is-zoomed' : '',
        colorToken ? `is-${colorToken}` : ''
      ].filter(Boolean).join(' ')}
      data-chat-pane-id={paneID}
      data-testid={`chat-pane-${paneID}`}
      aria-label={title || selectedThread?.title || 'Chat pane'}
      onPointerDownCapture={onActivate}
      onFocusCapture={onActivate}
    >
      {showsChrome ? (
        <header className="chat-pane-header" draggable onDragStart={onPaneDragStart}>
          <div className="chat-pane-identity">
            <span className="chat-pane-color" aria-hidden="true" />
            <span className="chat-pane-title">{title || selectedThread?.title || 'New conversation'}</span>
            {unseen ? <span className="chat-pane-unseen"><span className="sr-only">Unread completion</span></span> : null}
          </div>
          <BackendStrip
            compact
            idPrefix={`chat-pane-${paneID}`}
            backend={backend}
            modelLabel={modelLabel}
            modelOptionID={modelOptionID}
            thinkingLevel={thinkingLevel}
            config={config}
            catalog={catalog}
            thread={selectedThread}
            gatewayHint={null}
            onBackendChange={(value) => controller.getState().setBackend(value)}
            onModelOptionChange={(value) => controller.getState().setModelOption(value)}
            onThinkingLevelChange={(value) => controller.getState().setThinkingLevel(value)}
          />
          <div className="chat-pane-actions" role="toolbar" aria-label="Pane controls">
            <button type="button" onClick={onSplitHorizontal} title="Split left and right" aria-label="Split pane left and right">
              ◫
            </button>
            <button type="button" onClick={onSplitVertical} title="Split top and bottom" aria-label="Split pane top and bottom">
              ⊟
            </button>
            <button type="button" onClick={onToggleZoom} title={zoomed ? 'Restore all panes' : 'Zoom this pane'} aria-label={zoomed ? 'Restore all panes' : 'Zoom pane'}>
              {zoomed ? '↙' : '⛶'}
            </button>
            <details className="chat-pane-options">
              <summary title="Pane options" aria-label="Pane options">⋯</summary>
              <div className="chat-pane-options-menu">
                <label>
                  <span>Pane title</span>
                  <input
                    value={renameDraft}
                    maxLength={80}
                    onChange={(event) => setRenameDraft(event.target.value)}
                    onBlur={() => onRename(renameDraft)}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter') {
                        onRename(renameDraft);
                        event.currentTarget.blur();
                      }
                    }}
                  />
                </label>
                <label>
                  <span>Color</span>
                  <select
                    value={colorToken ?? ''}
                    onChange={(event) =>
                      onColorChange((event.target.value || null) as ChatWorkspaceColorToken | null)
                    }
                  >
                    <option value="">None</option>
                    {COLOR_OPTIONS.map((option) => (
                      <option key={option.id} value={option.id}>{option.label}</option>
                    ))}
                  </select>
                </label>
                <label className="chat-pane-checkbox">
                  <input
                    type="checkbox"
                    checked={alertsEnabled}
                    onChange={(event) => onAlertsChange(event.target.checked)}
                  />
                  <span>Completion alerts</span>
                </label>
                <button type="button" onClick={onMoveToNewTab}>Move to new tab</button>
                {otherTabs.map((tab) => (
                  <button key={tab.id} type="button" onClick={() => onMoveToTab(tab.id)}>
                    Move to {tab.title}
                  </button>
                ))}
                {unseen ? <button type="button" onClick={onMarkSeen}>Mark seen</button> : null}
              </div>
            </details>
            <button type="button" onClick={onClose} title="Close pane" aria-label="Close pane">×</button>
          </div>
        </header>
      ) : null}
      <div className="chat-main">
        {hasActiveTranscript ? (
          <MessageStream
            messages={messages}
            loading={messagesLoading}
            hasMoreBefore={hasMoreMessages}
            loadingOlderMessages={loadingOlderMessages}
            loadingAllMessages={loadingAllMessages}
            totalMessageCount={selectedThread?.messageCount}
            onLoadOlder={() => void controller.getState().loadOlderMessages()}
            onLoadAll={() => void controller.getState().loadAllMessages()}
            warnings={warnings}
            sharedFeaturesAvailable={sharedFeaturesAvailable}
            streamError={streamError}
            historyError={historyError}
            streaming={streaming}
            onOpenMissionControl={() => setRoute('missions')}
            onOpenCitation={(citation) => void openCitation(citation)}
            onToolApproval={(messageID, decision) =>
              void controller.getState().respondToToolApproval(messageID, decision)
            }
            onRetryToolApproval={(messageID) =>
              void controller.getState().retryToolApproval(messageID)
            }
          />
        ) : (
          <div className="chat-empty">
            <div>
              <p className="chat-empty-title">
                {threads.length === 0 ? 'No conversations yet' : 'New conversation'}
              </p>
              <p className="chat-empty-body">
                {threads.length === 0
                  ? 'Start a chat below to create your first durable conversation.'
                  : 'Write a message or drag a conversation here.'}
              </p>
            </div>
          </div>
        )}
        <Composer
          paneID={paneID}
          backend={backend}
          disabled={composerDisabled}
          disabledReason={composerDisabledReason}
          streaming={streaming}
          busy={streamPhase === 'composing'}
          onSend={sendComposerMessage}
          onStop={() => controller.getState().stopStreaming()}
        />
      </div>
      <p className="sr-only" aria-live="polite">{citationStatus ?? ''}</p>
    </div>
  );
}
