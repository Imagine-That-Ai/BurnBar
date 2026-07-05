export type FailureCase = { id: string; title: string; recovery: string };

/**
 * Failure/recovery rows (`li[data-failure-state]`) used by system routes.
 * Every case names the condition and the concrete recovery path.
 */
export function FailureStateList({ cases }: { cases: FailureCase[] }) {
  return (
    <ul className="failure-list">
      {cases.map((c) => (
        <li key={c.id} data-failure-state={c.id}>
          <strong>{c.title}</strong>
          <span>{c.recovery}</span>
        </li>
      ))}
    </ul>
  );
}
