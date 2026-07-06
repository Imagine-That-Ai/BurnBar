import { GlassAlert, GlassAlertStack, type GlassAlertSeverity } from './GlassAlert.js';

export type FailureCase = {
  id: string;
  title: string;
  recovery: string;
  severity?: GlassAlertSeverity;
  iconGlyph?: string;
};

function defaultSeverity(id: string): GlassAlertSeverity {
  if (id === 'network-offline') return 'warning';
  if (/secret|permission|quota|login|denied|channel/i.test(id)) return 'error';
  return 'warning';
}

/**
 * Failure/recovery alerts (`li[data-failure-state]`) used by system routes.
 */
export function FailureStateList({ cases }: { cases: FailureCase[] }) {
  return (
    <GlassAlertStack>
      <ul className="failure-list failure-list--alerts">
        {cases.map((c) => (
          <li key={c.id} data-failure-state={c.id}>
            <GlassAlert
              severity={c.severity ?? defaultSeverity(c.id)}
              title={c.title}
              description={c.recovery}
              iconGlyph={c.iconGlyph}
              role="status"
              className="glass-alert--ghost"
            />
          </li>
        ))}
      </ul>
    </GlassAlertStack>
  );
}