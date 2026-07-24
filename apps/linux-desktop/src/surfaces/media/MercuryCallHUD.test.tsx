// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { MercuryCallState } from '../../state/mediaStore.js';
import { MercuryCallHUD } from './MercuryCallHUD.js';

function renderHud(call: MercuryCallState) {
  const onAccept = vi.fn();
  const onDecline = vi.fn();
  const onEnd = vi.fn();
  render(<MercuryCallHUD call={call} error={null} onAccept={onAccept} onDecline={onDecline} onEnd={onEnd} />);
  return { onAccept, onDecline, onEnd };
}

describe('MercuryCallHUD', () => {
  afterEach(cleanup);

  it('renders idle state without action buttons', () => {
    renderHud({ phase: 'idle', kind: 'call', source: 'live' });
    expect(screen.getByText('Call viewer idle')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('renders ringing state and calls accept/decline handlers', () => {
    const { onAccept, onDecline } = renderHud({
      phase: 'ringing',
      requestId: 'req-1',
      peerName: 'Live iPhone',
      kind: 'call',
      source: 'live'
    });
    expect(screen.getByRole('heading', { name: 'Live iPhone' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Accept' }));
    fireEvent.click(screen.getByRole('button', { name: 'Decline' }));
    expect(onAccept).toHaveBeenCalledWith('req-1');
    expect(onDecline).toHaveBeenCalledWith('req-1');
  });

  it('renders streaming state and calls end handler', () => {
    const { onEnd } = renderHud({
      phase: 'streaming',
      requestId: 'req-1',
      peerName: 'Live iPhone',
      kind: 'call',
      startedAt: new Date().toISOString(),
      source: 'live'
    });
    expect(screen.getByText('Viewer streaming')).toBeTruthy();
    expect(screen.getByText(/Elapsed/)).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'End' }));
    expect(onEnd).toHaveBeenCalled();
  });

  it('renders cooldown state', () => {
    renderHud({
      phase: 'cooldown',
      requestId: 'req-1',
      peerName: 'Live iPhone',
      kind: 'call',
      source: 'live'
    });
    expect(screen.getByText('Call ended')).toBeTruthy();
    expect(screen.getByText(/Live iPhone disconnected/)).toBeTruthy();
  });

  it('renders capability-absent state and error alert', () => {
    render(
      <MercuryCallHUD
        call={{ phase: 'capability-absent', kind: 'call', source: 'absent' }}
        error="unknown method"
        onAccept={vi.fn()}
        onDecline={vi.fn()}
        onEnd={vi.fn()}
      />
    );
    expect(screen.getByText('Live calls unavailable')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('renders idle and degraded RPC states without false call controls', () => {
    render(
      <MercuryCallHUD
        call={{ phase: 'ringing', requestId: 'req-1', kind: 'call', source: 'live' }}
        error={null}
        controlState="idle"
        controlReason="Loading the daemon control contract."
        onAccept={vi.fn()}
        onDecline={vi.fn()}
        onEnd={vi.fn()}
      />
    );
    expect(screen.getByText('Call controls loading')).toBeTruthy();
    expect(screen.getByText('Loading the daemon control contract.')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();

    cleanup();
    render(
      <MercuryCallHUD
        call={{ phase: 'ringing', requestId: 'req-1', kind: 'call', source: 'live' }}
        error={null}
        controlState="degraded"
        controlReason="Daemon call control is unavailable."
        onAccept={vi.fn()}
        onDecline={vi.fn()}
        onEnd={vi.fn()}
      />
    );
    expect(screen.getByText('Call controls unavailable')).toBeTruthy();
    expect(screen.getByText('Daemon call control is unavailable.')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('renders control errors as alerts without action buttons', () => {
    render(
      <MercuryCallHUD
        call={{ phase: 'streaming', requestId: 'req-1', kind: 'call', source: 'live' }}
        error={null}
        controlState="error"
        controlReason="Daemon control probe failed."
        onAccept={vi.fn()}
        onDecline={vi.fn()}
        onEnd={vi.fn()}
      />
    );
    expect(screen.getByRole('alert')).toBeTruthy();
    expect(screen.getByText('Daemon control probe failed.')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });
});
