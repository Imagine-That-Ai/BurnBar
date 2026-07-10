// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type {
  LinuxShellBridge,
  ProviderExternalAuthFlowSnapshot
} from '../../tauriBridge.js';
import {
  resetProviderExternalAuthStoreForTests,
  useProviderExternalAuthStore
} from '../../state/providerExternalAuthStore.js';
import { useShellStore } from '../../state/shellStore.js';
import { ProviderExternalAuthPanel } from './ProviderExternalAuthPanel.js';

function flow(
  state: ProviderExternalAuthFlowSnapshot['state'],
  overrides: Partial<ProviderExternalAuthFlowSnapshot> = {}
): ProviderExternalAuthFlowSnapshot {
  const active = state === 'launching' || state === 'awaiting_user' || state === 'verifying';
  const terminal = state === 'succeeded' || state === 'failed' || state === 'cancelled' || state === 'timed_out';
  return {
    flowId: state === 'idle' ? undefined : 'flow-openai',
    providerId: 'openai',
    providerDisplayName: 'OpenAI',
    authMethodId: 'openai-codex-oauth',
    authMethodDisplayName: 'Sign in with OpenAI / Codex',
    cliDisplayName: 'Codex',
    state,
    availability: 'available',
    cliInstalled: true,
    connected: state === 'succeeded',
    startedAt: active || terminal ? '2026-07-10T12:00:00.000Z' : undefined,
    updatedAt: '2026-07-10T12:00:00.000Z',
    expiresAt: active ? '2026-07-10T12:05:00.000Z' : undefined,
    completedAt: terminal ? '2026-07-10T12:01:00.000Z' : undefined,
    ...overrides
  };
}

function bridge(overrides: Partial<LinuxShellBridge>): LinuxShellBridge {
  return overrides as LinuxShellBridge;
}

describe('ProviderExternalAuthPanel', () => {
  beforeEach(() => {
    resetProviderExternalAuthStoreForTests();
    useShellStore.setState({ fixtureMode: false, bridge: null, bridgeReady: true });
  });

  afterEach(() => {
    cleanup();
    resetProviderExternalAuthStoreForTests();
    vi.restoreAllMocks();
  });

  it('uses the daemon registry descriptor to start and cancel sign-in', async () => {
    const status = vi.fn(async () => flow('idle'));
    const start = vi.fn(async () => flow('awaiting_user'));
    const cancel = vi.fn(async () => flow('cancelled'));
    useShellStore.setState({
      bridge: bridge({
        providerExternalAuthStatus: status,
        providerExternalAuthStart: start,
        providerExternalAuthCancel: cancel
      })
    });

    render(<ProviderExternalAuthPanel providerID="openai" />);
    const signIn = await screen.findByRole('button', { name: 'Sign in with OpenAI / Codex' });
    fireEvent.click(signIn);
    await waitFor(() => expect(start).toHaveBeenCalledWith({
      providerId: 'openai',
      authMethodId: 'openai-codex-oauth'
    }));
    expect((await screen.findAllByText(/Terminal opened\. Finish Codex sign-in there/i)).length)
      .toBeGreaterThan(0);

    fireEvent.click(screen.getByRole('button', { name: 'Cancel sign-in' }));
    await waitFor(() => expect(cancel).toHaveBeenCalledWith('flow-openai'));
    expect((await screen.findAllByText(/sign-in was cancelled/i)).length).toBeGreaterThan(0);
  });

  it('disables sign-in when the daemon reports the CLI unavailable', async () => {
    useShellStore.setState({
      bridge: bridge({
        providerExternalAuthStatus: async () => flow('idle', {
          availability: 'unavailable',
          cliInstalled: false,
          problem: {
            code: 'executable_not_found',
            message: 'Codex CLI is not installed.',
            recoverable: true
          }
        })
      })
    });

    render(<ProviderExternalAuthPanel providerID="openai" />);
    const unavailable = await screen.findByRole('button', { name: 'Codex unavailable' });
    expect((unavailable as HTMLButtonElement).disabled).toBe(true);
    expect(screen.getAllByText('Codex CLI is not installed.').length).toBeGreaterThan(0);
  });

  it('announces and focuses terminal failure without rendering transport details', async () => {
    useShellStore.setState({
      bridge: bridge({
        providerExternalAuthStatus: async () => flow('failed', {
          problem: {
            code: 'verification_failed',
            message: 'Codex sign-in could not be verified. Try again.',
            recoverable: true
          }
        })
      })
    });

    render(<ProviderExternalAuthPanel providerID="openai" />);
    const alert = await screen.findByRole('alert');
    expect(alert.textContent).toContain('could not be verified');
    const heading = screen.getByRole('heading', { name: 'Sign in with OpenAI / Codex' });
    await waitFor(() => expect(document.activeElement).toBe(heading));
    expect(document.body.textContent).not.toContain('/tmp');
    expect(document.body.textContent).not.toContain('argv');
  });

  it('does not render a sign-in section for a registry-declared unsupported provider', async () => {
    useShellStore.setState({
      bridge: bridge({
        providerExternalAuthStatus: async () => flow('failed', {
          providerId: 'ollama',
          providerDisplayName: 'Ollama',
          authMethodId: 'unsupported',
          authMethodDisplayName: 'Unsupported sign-in method',
          cliDisplayName: 'Unavailable',
          availability: 'unavailable',
          cliInstalled: false,
          problem: {
            code: 'unsupported_provider',
            message: 'Ollama does not support external CLI sign-in.',
            recoverable: false
          }
        })
      })
    });
    const { container } = render(<ProviderExternalAuthPanel providerID="ollama" />);
    await waitFor(() => expect(useProviderExternalAuthStore.getState().snapshots.ollama).toBeDefined());
    expect(container.childElementCount).toBe(0);
    expect(screen.queryByText(/Unavailable unavailable/i)).toBeNull();
  });
});
