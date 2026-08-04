// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useChatStore, type ChatState } from '../../state/chatStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
import { PetChatBubble } from './PetChatBubble.js';

function resetState(): void {
  useShellStore.setState({
    bridge: null,
    bridgeReady: true,
    fixtureMode: false,
    runtimeCapabilities: null
  });
  useChatStore.setState({
    messages: [],
    streaming: false,
    streamPhase: 'idle',
    streamError: null,
    modelLabel: 'hermes'
  });
}

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('PetChatBubble', () => {
  beforeEach(resetState);

  it('stages a dropped file through the shared attachment policy', async () => {
    const consumed = vi.fn();
    render(
      <PetChatBubble
        droppedFile={new File(['hello'], 'notes.md', { type: 'text/markdown' })}
        onDroppedFileConsumed={consumed}
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
      />
    );

    expect((await screen.findByTestId('pet-chat-pending-attachment')).textContent).toContain('notes.md');
    expect(consumed).toHaveBeenCalledOnce();
    fireEvent.click(screen.getByRole('button', { name: 'Remove companion attachment notes.md' }));
    expect(screen.queryByTestId('pet-chat-pending-attachment')).toBeNull();
  });

  it('rejects unsupported dropped files visibly without staging them', () => {
    render(
      <PetChatBubble
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
      />
    );
    fireEvent.drop(screen.getByRole('dialog'), {
      dataTransfer: {
        types: ['Files'],
        files: [new File(['binary'], 'program.exe', { type: 'application/octet-stream' })]
      }
    });

    expect(screen.getByRole('alert').textContent).toMatch(/unsupported attachment type/i);
    expect(screen.queryByTestId('pet-chat-pending-attachment')).toBeNull();
  });

  it('uploads and sends a dropped attachment through the daemon-owned chat path', async () => {
    const upload = vi.fn(async () => ({
      attachmentId: 'attachment-1',
      fileName: 'notes.md',
      mimeType: 'text/markdown',
      byteSize: 5,
      sha256: 'a'.repeat(64)
    }));
    const sendMessage = vi.fn(async () => {});
    const bridge = {
      ...bridgeStubDefaults,
      chatAttachmentUpload: upload,
      gatewayAttachmentCapability: vi.fn()
    } as unknown as LinuxShellBridge;
    useShellStore.setState({ bridge });
    useChatStore.setState({ sendMessage } as Partial<ChatState>);

    render(
      <PetChatBubble
        droppedFile={new File(['hello'], 'notes.md', { type: 'text/markdown' })}
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
      />
    );
    fireEvent.change(screen.getByLabelText('Companion message'), {
      target: { value: 'Review this file' }
    });
    // The bubble hydrates the daemon-backed thread on mount; sending stays
    // disabled until that resume completes.
    await waitFor(() => {
      const send = screen.getByRole('button', { name: 'Send companion message' }) as HTMLButtonElement;
      expect(send.disabled).toBe(false);
    });
    fireEvent.click(screen.getByRole('button', { name: 'Send companion message' }));

    await waitFor(() => expect(sendMessage).toHaveBeenCalledOnce());
    expect(upload).toHaveBeenCalledWith(expect.objectContaining({
      fileName: 'notes.md',
      mimeType: 'text/markdown'
    }));
    expect(sendMessage).toHaveBeenCalledWith('Review this file', [
      expect.objectContaining({ attachmentId: 'attachment-1' })
    ]);
    expect(screen.queryByTestId('pet-chat-pending-attachment')).toBeNull();
  });
});
