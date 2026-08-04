// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { useChatStore, type ChatState } from '../../state/chatStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { bridgeStubDefaults } from '../../testing/bridgeStubs.js';
import type { LinuxShellBridge } from '../../tauriBridge.js';
import { PetChatBubble } from './PetChatBubble.js';

function stubMatchMedia(matches = false): void {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    value: vi.fn().mockImplementation((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  });
}

function resetState(): void {
  stubMatchMedia(false);
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

  it('emits companion behavior states as the user focuses and completes a turn', async () => {
    const onStateChange = vi.fn();
    const sendMessage = vi.fn(async () => {});
    useChatStore.setState({ sendMessage } as Partial<ChatState>);

    render(
      <PetChatBubble
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
        onStateChange={onStateChange}
      />
    );

    fireEvent.focus(screen.getByLabelText('Companion message'));
    fireEvent.change(screen.getByLabelText('Companion message'), { target: { value: 'Hello companion' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send companion message' }));

    await waitFor(() => expect(sendMessage).toHaveBeenCalledWith('Hello companion', undefined));
    expect(onStateChange).toHaveBeenCalledWith('listen');
    expect(onStateChange).toHaveBeenCalledWith('think');
    expect(onStateChange).toHaveBeenCalledWith('react');
    // The busy flag clearing must not immediately replace the reaction.
    await waitFor(() => expect(screen.getByRole('button', { name: 'Send companion message' })).toBeTruthy());
    expect(onStateChange.mock.calls.at(-1)).toEqual(['react']);
  });

  it('emits speak while a busy turn is streaming its reply', async () => {
    const onStateChange = vi.fn();
    let finishStream: () => void = () => {};
    const sendMessage = vi.fn(async () => {
      useChatStore.setState({ streaming: true, streamPhase: 'streaming' });
      await new Promise<void>((resolve) => {
        finishStream = resolve;
      });
      useChatStore.setState({ streaming: false, streamPhase: 'done' });
    });
    useChatStore.setState({ sendMessage } as Partial<ChatState>);

    render(
      <PetChatBubble
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
        onStateChange={onStateChange}
      />
    );
    fireEvent.change(screen.getByLabelText('Companion message'), { target: { value: 'Hello companion' } });
    fireEvent.click(screen.getByRole('button', { name: 'Send companion message' }));

    await waitFor(() => expect(onStateChange).toHaveBeenCalledWith('speak'));
    finishStream();
    await waitFor(() => expect(onStateChange).toHaveBeenCalledWith('react'));
  });

  it('emits alert when an unsupported attachment is rejected', async () => {
    const onStateChange = vi.fn();
    render(
      <PetChatBubble
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
        onStateChange={onStateChange}
      />
    );
    fireEvent.drop(screen.getByRole('dialog'), {
      dataTransfer: {
        types: ['Files'],
        files: [new File(['binary'], 'program.exe', { type: 'application/octet-stream' })]
      }
    });

    await waitFor(() => expect(onStateChange).toHaveBeenCalledWith('alert'));
  });

  it('resets the companion to idle when the bubble unmounts', () => {
    const onStateChange = vi.fn();
    const { unmount } = render(
      <PetChatBubble
        onClose={vi.fn()}
        onOpenFullChat={vi.fn()}
        onStateChange={onStateChange}
      />
    );
    unmount();
    expect(onStateChange).toHaveBeenLastCalledWith('idle');
  });
});
