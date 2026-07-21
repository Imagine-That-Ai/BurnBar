import { describe, expect, it } from 'vitest';
import {
  canonicalAttachmentMimeType,
  gatewayAttachmentUnsupportedMessage,
  isGatewayReadableAttachment,
  requiresGatewayAttachmentCapability
} from './chatAttachment.js';

describe('Linux chat attachment capability boundary', () => {
  it('canonicalizes generic browser MIME values from safe extensions', () => {
    expect(canonicalAttachmentMimeType('notes.md', 'application/octet-stream')).toBe('text/markdown');
    expect(canonicalAttachmentMimeType('DATA.JSON', '')).toBe('application/json');
    expect(canonicalAttachmentMimeType('notes.md', 'text/markdown')).toBe('text/markdown');
  });

  it('rejects MIME and extension mismatches before the native bridge', () => {
    expect(canonicalAttachmentMimeType('notes.md', 'application/pdf')).toBeNull();
    expect(canonicalAttachmentMimeType('installer.exe', 'application/octet-stream')).toBeNull();
  });

  it('keeps binary metadata distinct from text gateway content', () => {
    expect(canonicalAttachmentMimeType('brief.pdf', 'application/pdf')).toBe('application/pdf');
    expect(canonicalAttachmentMimeType('photo.PNG', 'image/png')).toBe('image/png');
    expect(isGatewayReadableAttachment('application/pdf')).toBe(false);
    expect(isGatewayReadableAttachment('text/plain')).toBe(true);
    expect(requiresGatewayAttachmentCapability('application/pdf')).toBe(true);
    expect(requiresGatewayAttachmentCapability('image/png')).toBe(true);
    expect(gatewayAttachmentUnsupportedMessage('application/pdf')).toMatch(/cannot read PDF content/i);
  });
});
