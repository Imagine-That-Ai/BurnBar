export function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const blockSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += blockSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + blockSize, bytes.length)));
  }
  return btoa(binary);
}

export function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

export function dataUrlByteLength(dataUrl: string): number {
  const separator = dataUrl.indexOf(',');
  if (separator < 0) {
    return new TextEncoder().encode(dataUrl).byteLength;
  }
  const metadata = dataUrl.slice(0, separator);
  const payload = dataUrl.slice(separator + 1);
  if (metadata.endsWith(';base64')) {
    const padding = payload.endsWith('==') ? 2 : payload.endsWith('=') ? 1 : 0;
    return Math.max(0, Math.floor((payload.length * 3) / 4) - padding);
  }
  return new TextEncoder().encode(decodeURIComponent(payload)).byteLength;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const copy = Uint8Array.from(bytes);
  const digest = await crypto.subtle.digest('SHA-256', copy.buffer);
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, '0'))
    .join('');
}
