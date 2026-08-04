import type {
  ChatAttachmentUploadRequest,
  ChatAttachmentUploadResult,
  LinuxShellBridge
} from '../../tauriBridge.js';
import type { PendingChatAttachment } from './chatAttachmentDraft.js';

/**
 * MIME types the Linux daemon can retain as attachment metadata. Binary sends
 * still require an explicit model capability result before they are uploaded.
 */
export const CHAT_ATTACHMENT_METADATA_MIME_TYPES = [
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json',
  'application/pdf',
  'image/png',
  'image/jpeg',
  'image/webp',
  'audio/mpeg',
  'audio/wav',
  'audio/mp4',
  'audio/aac',
  'audio/flac',
  'audio/aiff'
] as const;

export const CHAT_GATEWAY_TEXT_MIME_TYPES = [
  'text/plain',
  'text/markdown',
  'text/csv',
  'application/json'
] as const;

export const CHAT_GATEWAY_NATIVE_MIME_TYPES = [
  'application/pdf',
  'image/png',
  'image/jpeg',
  'image/webp',
  'audio/mpeg',
  'audio/wav',
  'audio/mp4',
  'audio/aac',
  'audio/flac',
  'audio/aiff'
] as const;

const MIME_BY_EXTENSION: Readonly<Record<string, (typeof CHAT_ATTACHMENT_METADATA_MIME_TYPES)[number]>> = {
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.markdown': 'text/markdown',
  '.csv': 'text/csv',
  '.json': 'application/json',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.flac': 'audio/flac',
  '.aif': 'audio/aiff',
  '.aiff': 'audio/aiff'
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

export function requiresGatewayAttachmentCapability(mimeType: string): boolean {
  return CHAT_GATEWAY_NATIVE_MIME_TYPES.includes(
    mimeType.trim().toLowerCase() as (typeof CHAT_GATEWAY_NATIVE_MIME_TYPES)[number]
  );
}

export function gatewayAttachmentUnsupportedMessage(mimeType: string): string {
  const normalized = mimeType.trim().toLowerCase();
  if (normalized === 'application/pdf') {
    return 'PDF attachments are staged safely, but this Linux chat gateway cannot read PDF content yet because the selected model does not declare PDF input support. Choose a text, Markdown, CSV, or JSON file, or select a model with PDF support.';
  }
  return 'This attachment type requires explicit model input support from the Linux daemon. Choose a text, Markdown, CSV, or JSON file, or select a model with matching image or audio input support.';
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

/**
 * Upload one staged attachment through the same daemon-owned boundary used by
 * the main composer. The pet bubble must not grow a second path-policy or
 * gateway-capability implementation.
 */
export async function uploadChatAttachmentForSend(
  bridge: LinuxShellBridge | null,
  fixtureMode: boolean,
  model: string,
  attachment: PendingChatAttachment
): Promise<ChatAttachmentUploadResult> {
  if (fixtureMode || !bridge) {
    throw new Error('Attachment transport requires the packaged Linux daemon.');
  }

  const request = await attachmentUploadRequest(attachment.file, attachment.name, attachment.type);
  const canonicalMimeType = canonicalAttachmentMimeType(request.fileName, request.mimeType);
  if (!canonicalMimeType) {
    throw new Error(gatewayAttachmentUnsupportedMessage(request.mimeType));
  }

  if (requiresGatewayAttachmentCapability(canonicalMimeType)) {
    const capability = await bridge.gatewayAttachmentCapability?.(model.trim() || 'hermes', canonicalMimeType);
    if (!capability || capability.state !== 'supported') {
      throw new Error(gatewayAttachmentUnsupportedMessage(canonicalMimeType));
    }
  } else if (!isGatewayReadableAttachment(canonicalMimeType)) {
    throw new Error(gatewayAttachmentUnsupportedMessage(canonicalMimeType));
  }

  return bridge.chatAttachmentUpload({ ...request, mimeType: canonicalMimeType });
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
