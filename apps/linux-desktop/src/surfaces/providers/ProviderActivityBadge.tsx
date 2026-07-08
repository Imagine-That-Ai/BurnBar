export function ProviderActivityBadge({ compact = false }: { compact?: boolean }) {
  return (
    <span className="provider-activity-badge" data-compact={compact ? 'true' : 'false'}>
      <span className="provider-activity-badge-pulse" aria-hidden="true" />
      {!compact ? <span className="provider-activity-badge-label">At work</span> : null}
    </span>
  );
}