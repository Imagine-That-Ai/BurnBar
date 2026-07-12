import { useEffect, useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';
import { MediaSection } from './MediaSection.js';

/**
 * Dedicated Mercury route (Phase 4). Uses media_status capability probe only —
 * no invented daemon.media.* RPCs. Transport remains iroh / remote-access-agent.
 */
export function MercurySurface() {
  const bridge = useShellStore((s) => s.bridge);
  const fixtureMode = useShellStore((s) => s.fixtureMode);
  const [capability, setCapability] = useState<'unknown' | 'available' | 'absent'>('unknown');
  const [detail, setDetail] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (fixtureMode) {
        if (!cancelled) {
          setCapability('absent');
          setDetail('Fixture mode: media capability-absent (matches live Linux honesty).');
        }
        return;
      }
      if (!bridge?.mediaStatus) {
        if (!cancelled) {
          setCapability('absent');
          setDetail('No media bridge command registered.');
        }
        return;
      }
      try {
        const status = (await bridge.mediaStatus()) as {
          capabilityAvailable?: boolean;
          reason?: string;
        };
        if (cancelled) return;
        if (status.capabilityAvailable) {
          setCapability('available');
          setDetail(null);
        } else {
          setCapability('absent');
          setDetail(status.reason ?? 'Mercury transport capability unavailable on this peer.');
        }
      } catch (err) {
        if (!cancelled) {
          setCapability('absent');
          setDetail(err instanceof Error ? err.message : String(err));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [bridge, fixtureMode]);

  return (
    <section className="surface-panel" aria-label="Mercury">
      <header style={{ marginBottom: '1rem' }}>
        <h2 style={{ margin: 0 }}>Mercury</h2>
        <p style={{ margin: '0.35rem 0 0', color: 'var(--color-text-mute)', fontSize: '0.85rem' }}>
          Pair, call, mirror, and file transfer through iroh / remote-access-agent — not invented media RPC names.
        </p>
      </header>
      {capability === 'absent' ? (
        <p role="status" style={{ color: 'var(--color-text-dim)', fontSize: '0.85rem' }}>
          {detail ?? 'Capability absent.'}
        </p>
      ) : null}
      <MediaSection />
    </section>
  );
}
