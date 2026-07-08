const tokenFmt = new Intl.NumberFormat('en-US');
const costFmt = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', minimumFractionDigits: 2 });
const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });

export function formatTokens(tokens: number): string {
  return tokenFmt.format(tokens);
}

export function formatCostUsd(costUsd: number): string {
  return costFmt.format(costUsd);
}

export function formatAbsoluteTime(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString();
}

export function formatRelativeTime(iso: string): string {
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return iso;
  const diffSec = Math.round((then - Date.now()) / 1000);
  const abs = Math.abs(diffSec);
  if (abs < 60) return rtf.format(diffSec, 'second');
  const diffMin = Math.round(diffSec / 60);
  if (Math.abs(diffMin) < 60) return rtf.format(diffMin, 'minute');
  const diffHr = Math.round(diffMin / 60);
  if (Math.abs(diffHr) < 48) return rtf.format(diffHr, 'hour');
  const diffDay = Math.round(diffHr / 24);
  return rtf.format(diffDay, 'day');
}

export function sessionDurationLabel(startedAt: string): string {
  const start = new Date(startedAt).getTime();
  if (Number.isNaN(start)) return '—';
  const mins = Math.max(0, Math.round((Date.now() - start) / 60_000));
  if (mins < 60) return `${mins} min`;
  const hrs = Math.floor(mins / 60);
  const rem = mins % 60;
  return rem ? `${hrs} h ${rem} min` : `${hrs} h`;
}