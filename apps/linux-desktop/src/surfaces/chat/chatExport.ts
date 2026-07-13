import type { ChatMessage, ChatMessageRole } from '../../state/chatStore.js';
import type {
  ChatMessageCursor,
  ChatThreadGetResult,
  ChatThreadSummary,
  PersistedChatMessage
} from '../../tauriBridge.js';

export type ChatExportFormat = 'json' | 'markdown';

/** Keep export/replay bounded even when a corrupted or runaway database reports an enormous count. */
export const CHAT_HISTORY_PAGE_SIZE = 500;
export const CHAT_HISTORY_MAX_MESSAGES = 10_000;
export const CHAT_HISTORY_MAX_CONTENT_BYTES = 16 * 1024 * 1024;
export const CHAT_HISTORY_MAX_PAGES = Math.ceil(CHAT_HISTORY_MAX_MESSAGES / CHAT_HISTORY_PAGE_SIZE);

export type ChatThreadPageFetcher = (
  threadID: string,
  maxMessages: number,
  before?: ChatMessageCursor
) => Promise<ChatThreadGetResult>;

type ExportMessage = {
  id: string;
  role: Extract<ChatMessageRole, 'user' | 'assistant' | 'system'>;
  content: string;
  timestamp?: string;
};

export type ChatExportDocument = {
  version: 1;
  thread: {
    id: string;
    title: string;
  };
  messages: ExportMessage[];
};

const PERSISTED_ROLES = new Set<ChatMessageRole>(['user', 'assistant', 'system']);

function isExportableRole(role: ChatMessageRole): role is ExportMessage['role'] {
  return PERSISTED_ROLES.has(role);
}

/** Keep only durable transcript fields; never serialize provider/tool/citation/gateway state. */
export function persistedMessagesForExport(threadID: string, messages: ChatMessage[]): ExportMessage[] {
  return messages.flatMap((message) => {
    if (
      message.threadID !== threadID ||
      !isExportableRole(message.role) ||
      message.text.trim().length === 0
    ) {
      return [];
    }
    return [{
      id: message.id,
      role: message.role,
      content: message.text,
      ...(message.timestamp ? { timestamp: message.timestamp } : {})
    }];
  });
}

export function buildChatExportDocument(
  thread: ChatThreadSummary,
  messages: ChatMessage[]
): ChatExportDocument {
  return {
    version: 1,
    thread: {
      id: thread.id,
      title: thread.title.trim() || 'Untitled chat'
    },
    messages: persistedMessagesForExport(thread.id, messages)
  };
}

export function sanitizeChatExportFilename(
  title: string,
  threadID: string,
  format: ChatExportFormat
): string {
  const source = title.normalize('NFKC').trim();
  const normalized = source
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/[\\/]+/g, '-')
    .replace(/[^\p{L}\p{N}._-]+/gu, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, 72);
  const fallback = threadID
    .normalize('NFKC')
    .replace(/[^\p{L}\p{N}._-]+/gu, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
    .slice(0, 24);
  const stem = normalized || fallback || 'thread';
  return `openburnbar-chat-${stem}.${format === 'markdown' ? 'md' : 'json'}`;
}

function markdownRole(role: ExportMessage['role']): string {
  return role[0].toUpperCase() + role.slice(1);
}

function markdownContent(content: string): string {
  return content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
}

export function serializeChatExport(document: ChatExportDocument, format: ChatExportFormat): string {
  if (format === 'json') {
    return `${JSON.stringify(document, null, 2)}\n`;
  }

  const lines = [`# ${document.thread.title.replace(/\n/g, ' ')}`, '', `Thread: ${document.thread.id}`, ''];
  for (const message of document.messages) {
    lines.push(`## ${markdownRole(message.role)}`);
    if (message.timestamp) lines.push(`_${message.timestamp}_`, '');
    lines.push(markdownContent(message.content), '');
  }
  return `${lines.join('\n').replace(/\n{3,}/g, '\n\n').trim()}\n`;
}

export type ChatExportDownload = {
  filename: string;
  content: string;
  mimeType: 'application/json' | 'text/markdown';
};

function messageCursor(message: PersistedChatMessage): ChatMessageCursor {
  return { timestamp: message.timestamp, messageID: message.id };
}

function historyMessageSize(message: PersistedChatMessage): number {
  return new TextEncoder().encode(message.content).length;
}

/**
 * Read the complete durable transcript from the daemon's stable cursor API.
 *
 * The renderer never assumes the currently visible page is the export. Pages
 * are fetched newest-first and prepended in chronological order. Bounds and
 * progress checks fail closed on malformed/corrupt daemon responses rather
 * than silently producing a partial file that looks complete.
 */
export async function loadCompleteChatHistory(
  thread: ChatThreadSummary,
  fetchPage: ChatThreadPageFetcher,
  options: {
    maxMessages?: number;
    maxContentBytes?: number;
    pageSize?: number;
  } = {}
): Promise<PersistedChatMessage[]> {
  const maxMessages = options.maxMessages ?? CHAT_HISTORY_MAX_MESSAGES;
  const maxContentBytes = options.maxContentBytes ?? CHAT_HISTORY_MAX_CONTENT_BYTES;
  const pageSize = options.pageSize ?? CHAT_HISTORY_PAGE_SIZE;
  if (
    !Number.isSafeInteger(maxMessages) ||
    maxMessages < 1 ||
    maxMessages > CHAT_HISTORY_MAX_MESSAGES ||
    !Number.isSafeInteger(maxContentBytes) ||
    maxContentBytes < 1 ||
    maxContentBytes > CHAT_HISTORY_MAX_CONTENT_BYTES ||
    !Number.isSafeInteger(pageSize) ||
    pageSize < 1 ||
    pageSize > CHAT_HISTORY_PAGE_SIZE
  ) {
    throw new Error('Chat history export bounds are invalid.');
  }

  const all: PersistedChatMessage[] = [];
  const seenIDs = new Set<string>();
  let contentBytes = 0;
  let before: ChatMessageCursor | undefined;

  for (let page = 0; page < CHAT_HISTORY_MAX_PAGES; page += 1) {
    const result = await fetchPage(thread.id, pageSize, before);
    if (!result.thread || result.thread.id !== thread.id) {
      throw new Error('Chat history response is missing its thread identity.');
    }
    if (result.messages.length === 0) {
      if (result.hasMoreBefore) {
        throw new Error('Chat history pagination made no progress.');
      }
      return all;
    }

    for (const message of result.messages) {
      if (message.threadID !== thread.id) {
        throw new Error('Chat history response contains a different thread.');
      }
      if (seenIDs.has(message.id)) {
        throw new Error('Chat history pagination returned a duplicate message.');
      }
      seenIDs.add(message.id);
      contentBytes += historyMessageSize(message);
      if (all.length >= maxMessages || contentBytes > maxContentBytes) {
        throw new Error('Chat history exceeds the safe export limit.');
      }
    }
    // The daemon returns each page oldest-to-newest; prepend the whole page so
    // ordering within a page remains stable.
    all.unshift(...result.messages);

    if (!result.hasMoreBefore) return all;
    const oldest = result.messages[0];
    const next = messageCursor(oldest);
    if (before && before.timestamp === next.timestamp && before.messageID === next.messageID) {
      throw new Error('Chat history pagination cursor did not advance.');
    }
    before = next;
  }

  throw new Error('Chat history exceeds the safe page limit.');
}

/** Convert daemon rows into the renderer-only shape used by the export serializer. */
export function chatMessagesForExport(messages: readonly PersistedChatMessage[]): ChatMessage[] {
  return messages.map((message) => ({
    id: message.id,
    threadID: message.threadID,
    role: message.role,
    text: message.content,
    timestamp: message.timestamp,
    attachments: message.attachments
  }));
}

/** Trigger the WebView's native download handoff without writing through renderer filesystem APIs. */
export function downloadChatExport(
  exportData: ChatExportDownload,
  document: Document | undefined = globalThis.document
): void {
  const url = globalThis.URL;
  if (
    !document?.body ||
    typeof Blob === 'undefined' ||
    !url ||
    typeof url.createObjectURL !== 'function' ||
    typeof url.revokeObjectURL !== 'function'
  ) {
    throw new Error('Chat export is unavailable in this shell.');
  }
  const blob = new Blob([exportData.content], { type: `${exportData.mimeType};charset=utf-8` });
  const objectURL = url.createObjectURL(blob);
  const anchor = document.createElement('a');
  anchor.href = objectURL;
  anchor.download = exportData.filename;
  anchor.rel = 'noopener';
  anchor.style.display = 'none';
  document.body.append(anchor);
  anchor.click();
  anchor.remove();
  if (typeof globalThis.setTimeout === 'function') {
    globalThis.setTimeout(() => url.revokeObjectURL(objectURL), 0);
  } else {
    url.revokeObjectURL(objectURL);
  }
}
