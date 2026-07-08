type QuotaConfidence = 'high' | 'medium' | 'low' | 'stale';

export function QuotaSourceBadge({
  source,
  confidence = 'medium'
}: {
  source: string;
  confidence?: QuotaConfidence;
}) {
  if (!source.trim()) return null;
  return (
    <span className="quota-source-badge" data-quota-confidence={confidence}>
      {source}
    </span>
  );
}