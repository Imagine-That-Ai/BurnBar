import type { ReactNode } from 'react';
import './GlassAlert.css';

export type GlassAlertSeverity = 'info' | 'warning' | 'error';

const SEVERITY_GLYPH: Record<GlassAlertSeverity, string> = {
  info: '◆',
  warning: '△',
  error: '⨯'
};

export type GlassAlertProps = {
  severity?: GlassAlertSeverity;
  title?: string;
  description?: string;
  iconGlyph?: string;
  /** 'none' renders without a live-region role — for static informational rows. */
  role?: 'alert' | 'status' | 'none';
  dismissible?: boolean;
  onDismiss?: () => void;
  actionLabel?: string;
  action?: ReactNode;
  children?: ReactNode;
  className?: string;
  as?: 'div' | 'button';
  onClick?: () => void;
  'aria-labelledby'?: string;
  'aria-describedby'?: string;
};

export function GlassAlert({
  severity = 'warning',
  title,
  description,
  iconGlyph,
  role = 'alert',
  dismissible = false,
  onDismiss,
  actionLabel,
  action,
  children,
  className = '',
  as = 'div',
  onClick,
  ...aria
}: GlassAlertProps) {
  const glyph = iconGlyph ?? SEVERITY_GLYPH[severity];
  const showAside = Boolean(actionLabel || action || dismissible);
  const classes = ['glass-alert', `glass-alert--${severity}`, className].filter(Boolean).join(' ');

  const body = (
    <>
      <span className="glass-alert-icon" aria-hidden="true">
        {glyph}
      </span>
      <div className="glass-alert-body">
        {title ? <p className="glass-alert-title">{title}</p> : null}
        {description ? <p className="glass-alert-description">{description}</p> : null}
      </div>
      {showAside ? (
        <div className="glass-alert-aside">
          {action ?? null}
          {actionLabel ? <span className="glass-alert-action-label">{actionLabel}</span> : null}
          {dismissible ? (
            <button
              type="button"
              className="glass-alert-dismiss"
              aria-label="Dismiss alert"
              onClick={(event) => {
                event.stopPropagation();
                onDismiss?.();
              }}
            >
              ×
            </button>
          ) : null}
        </div>
      ) : null}
      {children ? <div className="glass-alert-children">{children}</div> : null}
    </>
  );

  const liveRole = role === 'none' ? undefined : role;

  if (as === 'button') {
    return (
      <button type="button" className={classes} role={liveRole} onClick={onClick} {...aria}>
        {body}
      </button>
    );
  }

  return (
    <div className={classes} role={liveRole} {...aria}>
      {body}
    </div>
  );
}

export function GlassAlertStack({
  children,
  className = '',
  inline = false
}: {
  children: ReactNode;
  className?: string;
  inline?: boolean;
}) {
  return (
    <div
      className={['glass-alert-stack', inline ? 'glass-alert-stack--inline' : '', className].filter(Boolean).join(' ')}
      role="group"
      aria-label="Status alerts"
    >
      {children}
    </div>
  );
}

export function daemonToneToSeverity(tone: 'ok' | 'warn' | 'err'): GlassAlertSeverity {
  if (tone === 'ok') return 'info';
  if (tone === 'err') return 'error';
  return 'warning';
}