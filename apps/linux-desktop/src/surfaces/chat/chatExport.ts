import type { ChatMessage, ChatMessageRole } from '../../state/chatStore.js';
import type { ChatThreadSummary } from '../../tauriBridge.js';

export type ChatExportFormat = 'json' | 'markdown';

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
