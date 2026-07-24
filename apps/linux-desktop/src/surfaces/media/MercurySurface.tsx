import { useEffect, useState } from 'react';
import { useShellStore } from '../../state/shellStore.js';
import { MediaSection } from './MediaSection.js';
import type { MercuryMediaStatus } from '../../tauriBridge.js';

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
        const status = (await bridge.mediaStatus()) as MercuryMediaStatus;
        if (cancelled) return;
        const viewer = status.viewerCapability;
        const available = viewer?.available ?? status.capabilityAvailable;
        if (available) {
          setCapability('available');
          setDetail(null);
        } else {
          setCapability('absent');
          setDetail(viewer ? viewerDetail(viewer) : status.reason ?? 'Mercury transport capability unavailable on this peer.');
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

function viewerDetail(viewer: NonNullable<MercuryMediaStatus['viewerCapability']>): string {
  const reason = (() => {
    switch (viewer.status) {
      case 'built_without_gstreamer':
        return 'This Linux build was compiled without the GStreamer viewer feature.';
      case 'gstreamer_backend_unavailable':
        return 'The GStreamer runtime is unavailable to the packaged shell.';
      case 'gstreamer_vp9_decoder_missing':
        return 'The GStreamer runtime is missing a VP9 decoder.';
      case 'gstreamer_video_sink_missing':
        return 'The GStreamer runtime is missing a native video sink.';
      case 'unknown':
        return viewer.reason ?? 'The packaged shell cannot verify a native Mercury video viewer.';
      case 'available':
        return 'The native Mercury viewer is ready.';
    }
  })();
  return viewer.installHint ? `${reason} ${viewer.installHint}` : reason;
}
