export function ReadOnlyToggle({ checked, label }: { checked: boolean; label: string }) {
  return (
    <label className="setting-toggle setting-toggle--readonly">
      <input
        type="checkbox"
        checked={checked}
        disabled
        aria-disabled="true"
        aria-label={label}
        readOnly
      />
      <span className="muted">Managed by daemon config</span>
    </label>
  );
}