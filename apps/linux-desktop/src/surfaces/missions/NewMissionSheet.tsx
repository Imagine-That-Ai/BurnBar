import { useCallback, useEffect, useId, useState, type FormEvent } from 'react';
import { useMissionsStore } from '../../state/missionsStore.js';
import type { ProjectEntry } from '../../tauriBridge.js';
import { RunwayInsignia } from './RunwayInsignia.js';

export function NewMissionSheet({
  open,
  onClose,
  projects,
  defaultProjectSlug,
  onSubmitted
}: {
  open: boolean;
  onClose: () => void;
  projects: ProjectEntry[];
  defaultProjectSlug: string | null;
  onSubmitted?: () => void;
}) {
  const titleId = useId();
  const [projectSlug, setProjectSlug] = useState('');
  const [title, setTitle] = useState('');
  const [summary, setSummary] = useState('');
  const [notice, setNotice] = useState<string | null>(null);
  const submitting = useMissionsStore((s) => s.creating);
  const createError = useMissionsStore((s) => s.createError);
  const createMission = useMissionsStore((s) => s.create);

  useEffect(() => {
    if (!open) return;
    setNotice(null);
    setTitle('');
    setSummary('');
    const fallback =
      defaultProjectSlug ??
      projects[0]?.id ??
      projects[0]?.name?.toLowerCase().replace(/\s+/g, '-') ??
      '';
    setProjectSlug(fallback);
  }, [open, defaultProjectSlug, projects]);

  const canSubmit =
    projectSlug.trim().length > 0 &&
    title.trim().length > 0 &&
    summary.trim().length > 0 &&
    !submitting;
  const onSubmit = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      if (!canSubmit) return;
      const ok = await createMission({
        projectSlug: projectSlug.trim(),
        title: title.trim(),
        summary: summary.trim()
      });
      if (ok) {
        setNotice('Mission filed through the daemon.');
        onSubmitted?.();
        onClose();
      }
    },
    [canSubmit, createMission, onClose, onSubmitted, projectSlug, summary, title]
  );

  if (!open) return null;

  return (
    <div className="missions-sheet-backdrop" role="presentation" onClick={onClose}>
      <div
        className="missions-sheet card"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        onClick={(e) => e.stopPropagation()}
      >
        <header className="missions-sheet-header">
          <RunwayInsignia size={34} />
          <div>
            <p className="missions-sheet-kicker">NEW MISSION</p>
            <h2 id={titleId} className="missions-sheet-title">
              File new mission
            </h2>
            <p className="muted missions-sheet-lead">
              Project slug, title, and summary mirror the macOS authoring sheet. Submit files the mission through
              the local daemon.
            </p>
          </div>
          <button type="button" className="missions-sheet-close" onClick={onClose} aria-label="Close">
            ×
          </button>
        </header>

        <form className="missions-sheet-form" onSubmit={onSubmit}>
          <label className="missions-sheet-field">
            <span className="missions-sheet-label">
              Project <span className="missions-sheet-required">required</span>
            </span>
            <div className="missions-sheet-project-row">
              <input
                className="missions-sheet-input mono"
                value={projectSlug}
                onChange={(e) => setProjectSlug(e.target.value)}
                placeholder="project-slug"
                autoComplete="off"
                list={projects.length > 0 ? `${titleId}-projects` : undefined}
              />
              {projects.length > 0 ? (
                <datalist id={`${titleId}-projects`}>
                  {projects.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </datalist>
              ) : null}
              {projects.length > 1 ? (
                <select
                  className="missions-sheet-select"
                  value={projectSlug}
                  onChange={(e) => setProjectSlug(e.target.value)}
                  aria-label="Registered projects"
                >
                  {projects.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
                </select>
              ) : null}
            </div>
          </label>

          <label className="missions-sheet-field">
            <span className="missions-sheet-label">
              Title <span className="missions-sheet-required">required</span>
            </span>
            <input
              className="missions-sheet-input"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Mission title"
            />
          </label>

          <label className="missions-sheet-field">
            <span className="missions-sheet-label">
              Summary <span className="missions-sheet-required">required</span>
            </span>
            <textarea
              className="missions-sheet-textarea"
              value={summary}
              onChange={(e) => setSummary(e.target.value)}
              placeholder="What should this mission accomplish?"
              rows={4}
            />
          </label>

          {notice ? (
            <p className="missions-sheet-notice" role="status">
              {notice}
            </p>
          ) : null}
          {createError ? (
            <p className="missions-sheet-notice" role="alert">
              {createError}
            </p>
          ) : null}

          <div className="missions-sheet-actions">
            <button type="button" className="missions-gate-btn missions-gate-btn--secondary" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="missions-gate-btn missions-gate-btn--primary"
              disabled={!canSubmit}
            >
              {submitting ? 'Submitting…' : 'File mission'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
