import { useEffect, useState } from 'react';
import type { LinuxShellBridge, NativeShellSnapshot } from '../../tauriBridge.js';
import { SettingRow } from './SettingRow.js';

export function NativeShellSettings({ bridge }: { bridge: LinuxShellBridge | null }) {
  const [snapshot, setSnapshot] = useState<NativeShellSnapshot | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!bridge) return;
    let disposed = false;
    let unlisten: (() => void) | null = null;
    void bridge
      .onNativeShellState((next) => {
        if (!disposed) setSnapshot(next);
      })
      .then(async (removeListener) => {
        if (disposed) {
          removeListener();
          return;
        }
        unlisten = removeListener;
        const next = await bridge.nativeShellSnapshot();
        if (!disposed) setSnapshot(next);
      })
      .catch((cause) => {
        if (!disposed) {
          setError(cause instanceof Error ? cause.message : 'Native shell status failed.');
        }
      });
    return () => {
      disposed = true;
      unlisten?.();
    };
  }, [bridge]);

  const setLoginStart = async (enabled: boolean) => {
    if (!bridge || busy) return;
    setBusy(true);
    setError(null);
    try {
      setSnapshot(await bridge.nativeShellSetLoginStart(enabled));
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Login-start update failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <SettingRow
        iconGlyph="↻"
        label="Start at login"
        description="Launch OpenBurnBar in the background through your user-owned XDG autostart entry."
        control={
          <label className="setting-toggle setting-toggle--writable">
            <input
              type="checkbox"
              checked={snapshot?.loginStartEnabled ?? false}
              disabled={!bridge || !snapshot || busy || Boolean(snapshot.degradedReason)}
              onChange={(event) => void setLoginStart(event.currentTarget.checked)}
              aria-label="Start OpenBurnBar at login"
            />
            <span aria-hidden="true" />
          </label>
        }
      />
      {snapshot?.loginStartPath ? (
        <p className="system-path-row">
          <code>{snapshot.loginStartPath}</code>
        </p>
      ) : null}
      {snapshot?.degradedReason || error ? (
        <p className="settings-native-shell-error" role="alert">
          {error ?? snapshot?.degradedReason}
        </p>
      ) : null}
    </>
  );
}
