import { CHAT_ATTACHMENT_METADATA_MIME_TYPES } from './chatAttachment.js';

export const MAX_CHAT_ATTACHMENT_BYTES = 10 * 1024 * 1024;

export const CHAT_ATTACHMENT_ACCEPT = [
  ...CHAT_ATTACHMENT_METADATA_MIME_TYPES,
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.json',
  '.pdf',
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.mp3',
  '.wav',
  '.m4a',
  '.aac',
  '.flac',
  '.aif',
  '.aiff'
] as const;

const CHAT_ATTACHMENT_EXTENSIONS = new Set([
  '.txt',
  '.md',
  '.markdown',
  '.csv',
  '.json',
  '.pdf',
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.mp3',
  '.wav',
  '.m4a',
  '.aac',
  '.flac',
  '.aif',
  '.aiff'
]);

export type PendingChatAttachment = {
  name: string;
  size: number;
  type: string;
  lastModified: number;
  /** Kept in memory only until the daemon accepts the upload. */
  file: File;
};

export type ChatAttachmentInspection = {
  attachment: PendingChatAttachment | null;
  error: string | null;
};

/**
 * Apply the same bounded file policy to picker and drag-and-drop inputs.
 * Keeping this pure makes the pet drop target and the main composer share one
 * acceptance contract instead of silently drifting apart.
 */
export function inspectChatAttachment(file: File): ChatAttachmentInspection {
  if (file.size > MAX_CHAT_ATTACHMENT_BYTES) {
    return { attachment: null, error: 'Attachment exceeds the 10 MB limit.' };
  }

  const type = file.type.trim().toLowerCase();
  const extension = file.name.slice(file.name.lastIndexOf('.')).toLowerCase();
  if (
    !CHAT_ATTACHMENT_METADATA_MIME_TYPES.includes(
      type as (typeof CHAT_ATTACHMENT_METADATA_MIME_TYPES)[number]
    ) &&
    !CHAT_ATTACHMENT_EXTENSIONS.has(extension)
  ) {
    return {
      attachment: null,
      error: 'Unsupported attachment type. Choose text, JSON, CSV, Markdown, PDF, PNG, JPEG, WebP, or audio.'
    };
  }

  return {
    attachment: {
      name: file.name,
      size: file.size,
      type: type || 'application/octet-stream',
      lastModified: file.lastModified,
      file
    },
    error: null
  };
}
