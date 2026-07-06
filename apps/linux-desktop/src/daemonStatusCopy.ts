export type DaemonStatusTone = 'ok' | 'warn' | 'err';

export type DaemonStatusCopy = {
  label: string;
  detail: string;
  tone: DaemonStatusTone;
  ok: boolean;
  rawDetail?: string;
};

export type DaemonStatusInput = {
  ok: boolean;
  daemonVersion?: string;
  socketPath?: string;
  fixtureMode: boolean;
  bridgeAvailable: boolean;
  healthError?: string | null;
  daemonError?: string | null;
  displaySocketPath: string;
};

export function buildDaemonStatusCopy(input: DaemonStatusInput): DaemonStatusCopy {
  if (input.ok) {
    return {
      label: `Daemon ${input.daemonVersion ?? 'ready'}${input.fixtureMode ? ' (fixture)' : ''}`,
      detail: `Connected over AF_UNIX at ${input.socketPath ?? input.displaySocketPath}.`,
      tone: 'ok',
      ok: true
    };
  }

  if (!input.bridgeAvailable) {
    return {
      label: 'Browser preview mode',
      detail: 'Run the packaged Linux app to probe the local daemon socket.',
      tone: 'warn',
      ok: false,
      rawDetail: input.healthError ?? undefined
    };
  }

  const raw = input.healthError ?? input.daemonError ?? '';
  if (/no such file|os error 2|enoent/i.test(raw)) {
    return {
      label: 'Daemon offline',
      detail: `No daemon socket was found at ${input.displaySocketPath}. Start the OpenBurnBar daemon, then retry.`,
      tone: 'err',
      ok: false,
      rawDetail: raw
    };
  }
  if (/permission|denied|eacces/i.test(raw)) {
    return {
      label: 'Daemon permission blocked',
      detail: `The app cannot access ${input.displaySocketPath}. Check socket ownership and the current user session.`,
      tone: 'err',
      ok: false,
      rawDetail: raw
    };
  }
  if (/connection refused|reset|closed/i.test(raw)) {
    return {
      label: 'Daemon not accepting connections',
      detail: 'The daemon socket exists but the health probe could not complete. Restart the daemon and retry.',
      tone: 'err',
      ok: false,
      rawDetail: raw
    };
  }
  return {
    label: 'Daemon unavailable',
    detail: 'The local peer is not reachable yet. Dashboard routes stay local-only until the daemon responds.',
    tone: raw ? 'err' : 'warn',
    ok: false,
    rawDetail: raw || undefined
  };
}
