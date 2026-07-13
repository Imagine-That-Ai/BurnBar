import type { ChatAttachmentUploadRequest } from '../../tauriBridge.js';

/** Convert a browser File to the bounded upload envelope without exposing a path. */
export async function attachmentUploadRequest(
  file: File,
  fileName: string,
  mimeType: string
): Promise<ChatAttachmentUploadRequest> {
  const bytes = new Uint8Array(await readFileBytes(file));
  let binary = '';
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  const contentBase64 = globalThis.btoa(binary);
  return { fileName, mimeType, contentBase64 };
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
