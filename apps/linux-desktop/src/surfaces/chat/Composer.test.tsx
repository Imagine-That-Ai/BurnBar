// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { MAX_CHAT_ATTACHMENT_BYTES, Composer } from './Composer.js';

function renderComposer() {
  return render(
    <Composer
      backend="hermes"
      disabled={false}
      disabledReason=""
      streaming={false}
      busy={false}
      onSend={vi.fn()}
      onStop={vi.fn()}
    />
  );
}

afterEach(() => cleanup());

describe('chat composer attachments', () => {
  it('shows accepted file metadata, disables send, and removes it cleanly', () => {
    renderComposer();
    const composer = screen.getByLabelText('Message composer');
    fireEvent.change(composer, { target: { value: 'summarize this' } });
    const file = new File(['hello'], 'notes.md', { type: 'text/markdown', lastModified: 10 });
    fireEvent.change(screen.getByLabelText('Attachment file'), { target: { files: [file] } });

    expect(screen.getByTestId('pending-attachment').textContent).toContain('notes.md');
    expect(screen.getByRole('button', { name: 'Send message' })).toHaveProperty('disabled', true);
    fireEvent.click(screen.getByRole('button', { name: 'Remove attachment notes.md' }));
    expect(screen.queryByTestId('pending-attachment')).toBeNull();
    expect(screen.getByRole('button', { name: 'Send message' })).toHaveProperty('disabled', false);
  });

  it('shows visible errors for size and type bounds without staging a file', () => {
    renderComposer();
    const input = screen.getByLabelText('Attachment file');
    const oversized = new File([new Uint8Array(MAX_CHAT_ATTACHMENT_BYTES + 1)], 'large.txt', {
      type: 'text/plain'
    });
    fireEvent.change(input, { target: { files: [oversized] } });
    expect(screen.getByRole('alert').textContent).toMatch(/10 MB limit/i);
    expect(screen.queryByTestId('pending-attachment')).toBeNull();

    const unsupported = new File(['binary'], 'program.exe', { type: 'application/octet-stream' });
    fireEvent.change(input, { target: { files: [unsupported] } });
    expect(screen.getByRole('alert').textContent).toMatch(/Unsupported attachment type/i);
  });
});
