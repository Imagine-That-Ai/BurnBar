// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { configureTextExpansionConsentStorage, writeTextExpansionConsent } from '../../textExpansionConsent.js';
import { configureTextExpansionStorage, upsertSnippet } from '../../textExpansionStore.js';
import { MAX_CHAT_ATTACHMENT_BYTES, Composer } from './Composer.js';

function renderComposer(secureField = false) {
  return render(
    <Composer
      backend="hermes"
      disabled={false}
      disabledReason=""
      streaming={false}
      busy={false}
      secureField={secureField}
      onSend={vi.fn()}
      onStop={vi.fn()}
    />
  );
}

afterEach(() => {
  cleanup();
  configureTextExpansionStorage(null);
  configureTextExpansionConsentStorage(null, true);
});

function enableInAppExpansion() {
  writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
  upsertSnippet({ title: 'Signature', trigger: ';;sig', body: 'Thanks', enabled: true });
}

describe('chat composer attachments', () => {
  it('shows accepted file metadata, keeps send available, and removes it cleanly', () => {
    renderComposer();
    const composer = screen.getByLabelText('Message composer');
    fireEvent.change(composer, { target: { value: 'summarize this' } });
    const file = new File(['hello'], 'notes.md', { type: 'text/markdown', lastModified: 10 });
    fireEvent.change(screen.getByLabelText('Attachment file'), { target: { files: [file] } });

    expect(screen.getByTestId('pending-attachment').textContent).toContain('notes.md');
    expect(screen.getByRole('button', { name: 'Send message' })).toHaveProperty('disabled', false);
    expect(screen.getByLabelText('Attachment file')).toHaveProperty('accept', expect.stringContaining('.md'));
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

  it('passes the selected file to the daemon upload boundary before clearing it', async () => {
    const onSend = vi.fn(async (_text: string, attachment?: { file: File }) => {
      expect(attachment?.file.name).toBe('notes.md');
      return true;
    });
    render(
      <Composer
        backend="hermes"
        disabled={false}
        disabledReason=""
        streaming={false}
        busy={false}
        onSend={onSend}
        onStop={vi.fn()}
      />
    );
    fireEvent.change(screen.getByLabelText('Message composer'), { target: { value: 'Review this' } });
    fireEvent.change(screen.getByLabelText('Attachment file'), {
      target: { files: [new File(['hello'], 'notes.md', { type: 'text/markdown' })] }
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send message' }));
    await waitFor(() => expect(onSend).toHaveBeenCalledOnce());
    expect(screen.queryByTestId('pending-attachment')).toBeNull();
  });
});

describe('chat composer text expansion', () => {
  it('expands a consented in-app trigger as the user types', () => {
    enableInAppExpansion();
    renderComposer();
    const composer = screen.getByLabelText('Message composer');
    fireEvent.change(composer, { target: { value: 'reply ;;sig' } });
    expect(composer).toHaveProperty('value', 'reply Thanks');
  });

  it('does not expand a secure field', () => {
    enableInAppExpansion();
    renderComposer(true);
    const composer = screen.getByLabelText('Message composer');
    fireEvent.change(composer, { target: { value: 'reply ;;sig' } });
    expect(composer).toHaveProperty('value', 'reply ;;sig');
  });
});
