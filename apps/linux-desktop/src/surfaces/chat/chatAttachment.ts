import type { ChatAttachmentUploadRequest } from '../../tauriBridge.js';

/**
 * MIME types the Linux daemon can retain as attachment metadata. The gateway
 * currently expands only UTF-8 text into a provider request; PDF metadata is
 * intentionally accepted for export/recovery but is not gateway-readable yet.
 */
export const CHAT_ATTACHMENT_METADATA_MIME_TYPES = [
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
  'application/pdf'
] as const;

export const CHAT_GATEWAY_TEXT_MIME_TYPES = [
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json'
] as const;

const MIME_BY_EXTENSION: Readonly<Record<string, (typeof CHAT_ATTACHMENT_METADATA_MIME_TYPES)[number]>> = {
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.markdown': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.pdf': 'application/pdf'
};

/**
 * Match the native daemon's extension/MIME policy before bytes cross the
 * bridge. Browsers on Linux often report an empty or generic MIME type.
 */
export function canonicalAttachmentMimeType(fileName: string, mimeType: string): string | null {
  const normalizedName = fileName.trim();
  const extensionStart = normalizedName.lastIndexOf('.');
  const extension = extensionStart >= 0 ? normalizedName.slice(extensionStart).toLowerCase() : '';
  const inferred = MIME_BY_EXTENSION[extension];
  const normalizedMime = mimeType.trim().toLowerCase();
  const canonical = !normalizedMime || normalizedMime === 'application/octet-stream'
    ? inferred
    : CHAT_ATTACHMENT_METADATA_MIME_TYPES.includes(
        normalizedMime as (typeof CHAT_ATTACHMENT_METADATA_MIME_TYPES)[number]
      )
      ? normalizedMime as (typeof CHAT_ATTACHMENT_METADATA_MIME_TYPES)[number]
      : undefined;
  if (!canonical || (inferred && inferred !== canonical)) return null;
  return canonical;
}

export function isGatewayReadableAttachment(mimeType: string): boolean {
  return CHAT_GATEWAY_TEXT_MIME_TYPES.includes(
    mimeType.trim().toLowerCase() as (typeof CHAT_GATEWAY_TEXT_MIME_TYPES)[number]
  );
}

export function gatewayAttachmentUnsupportedMessage(mimeType: string): string {
  const normalized = mimeType.trim().toLowerCase();
  if (normalized === 'application/pdf') {
    return 'PDF attachments are staged safely, but this Linux chat gateway cannot read PDF content yet. Choose a text, Markdown, CSV, or JSON file.';
  }
  return 'This attachment type is not readable by the Linux chat gateway yet. Choose a text, Markdown, CSV, or JSON file.';
}

/** Convert a browser File to the bounded upload envelope without exposing a path. */
export async function attachmentUploadRequest(
  file: File,
  fileName: string,
  mimeType: string
): Promise<ChatAttachmentUploadRequest> {
  const canonicalMimeType = canonicalAttachmentMimeType(fileName, mimeType);
  if (!canonicalMimeType) {
    throw new Error('Unsupported attachment type or MIME/extension mismatch.');
  }
  const bytes = new Uint8Array(await readFileBytes(file));
  let binary = '';
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  const contentBase64 = globalThis.btoa(binary);
  return { fileName: fileName.trim(), mimeType: canonicalMimeType, contentBase64 };
}

async function readFileBytes(file: File): Promise<ArrayBuffer> {
  if (typeof file.arrayBuffer === 'function') return file.arrayBuffer();
  return new Promise<ArrayBuffer>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      if (reader.result instanceof ArrayBuffer) resolve(reader.result);
      else reject(new Error('Attachment bytes could not be read.'));
    };
    reader.onerror = () => reject(reader.error ?? new Error('Attachment bytes could not be read.'));
    reader.readAsArrayBuffer(file);
  });
}
