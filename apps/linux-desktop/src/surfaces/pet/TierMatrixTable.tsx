import { DataTable } from '../../components/DataTable.js';
import { petTierMatrix } from '../../shellEvidenceModel.js';

/**
 * Per-desktop-environment pet tier expectations from the evidence model.
 */
export function TierMatrixTable() {
  const rows = petTierMatrix().map((entry) => ({
    id: (entry.desktop ?? 'unknown').toLowerCase().replace(/\s+/g, '-'),
    title: entry.desktop ?? 'unknown',
    detail: `${entry.tier ?? 'unknown'} — ${entry.evidence ?? ''}`
  }));
  return <DataTable rows={rows} sourceLabel="pet tier matrix (evidence model)" />;
}