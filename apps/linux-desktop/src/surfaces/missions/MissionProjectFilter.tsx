import type { ProjectEntry } from '../../tauriBridge.js';

export function MissionProjectFilter({
  value,
  options,
  onChange
}: {
  value: string | null;
  options: { id: string; label: string }[];
  onChange: (projectId: string | null) => void;
}) {
  if (options.length === 0) return null;

  const selectValue = value ?? '';

  return (
    <label className="missions-project-filter">
      <span className="visually-hidden">Filter missions by project</span>
      <span className="missions-project-filter-icon" aria-hidden="true">
        ▣
      </span>
      <select
        className="missions-project-filter-select"
        value={selectValue}
        onChange={(e) => {
          const v = e.target.value;
          onChange(v.length > 0 ? v : null);
        }}
      >
        <option value="">All projects</option>
        {options.map((opt) => (
          <option key={opt.id} value={opt.id}>
            {opt.label}
          </option>
        ))}
      </select>
    </label>
  );
}

export function buildProjectFilterOptions(
  missionProjectSlugs: string[],
  projects: ProjectEntry[] | null
): { id: string; label: string }[] {
  const byId = new Map<string, string>();
  for (const slug of missionProjectSlugs) {
    byId.set(slug, slug);
  }
  if (projects) {
    for (const p of projects) {
      byId.set(p.id, p.name || p.id);
    }
  }
  return [...byId.entries()]
    .map(([id, label]) => ({ id, label }))
    .sort((a, b) => a.label.localeCompare(b.label));
}