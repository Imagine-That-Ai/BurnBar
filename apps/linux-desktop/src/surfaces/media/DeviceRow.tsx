import type { MercuryPairedDevice } from '../../tauriBridge.js';

const GLYPHS: Record<MercuryPairedDevice['platform'], string> = {
  ios: 'iOS',
  android: 'And',
  macos: 'Mac',
  linux: 'Lin',
  unknown: 'Dev'
};

function relativeTime(iso: string): string {
  const time = new Date(iso).getTime();
  if (!Number.isFinite(time)) return 'Last seen unknown';
  const seconds = Math.max(0, Math.floor((Date.now() - time) / 1000));
  if (seconds < 60) return 'Seen just now';
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `Seen ${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `Seen ${hours}h ago`;
  return `Seen ${Math.floor(hours / 24)}d ago`;
}

export function DeviceRow({ device }: { device: MercuryPairedDevice }) {
  return (
    <li className="p12-device-row">
      <span className="p12-device-glyph" aria-hidden="true">
        {GLYPHS[device.platform]}
      </span>
      <span>
        <strong>
          <span className={`p12-online-dot ${device.isOnline ? 'online' : 'offline'}`} aria-hidden="true" />
          {device.name}
        </strong>
        <small>
          {device.isOnline ? 'Online' : 'Offline'} · {relativeTime(device.lastSeenAt)}
        </small>
        <small>{device.capabilities.length > 0 ? device.capabilities.join(' · ') : 'No advertised capabilities'}</small>
      </span>
    </li>
  );
}
