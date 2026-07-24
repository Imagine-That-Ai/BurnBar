import type { ButtonHTMLAttributes, ReactNode } from 'react';

export type GlassButtonVariant = 'prominent' | 'regular' | 'cool';

export type GlassButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  children?: ReactNode;
  /** Mirrors macOS GlassButton.Style without colliding with React's style prop. */
  variant?: GlassButtonVariant;
};

/** Typed Linux counterpart to macOS GlassButton. */
export function GlassButton({
  children,
  className = '',
  type = 'button',
  variant = 'regular',
  ...props
}: GlassButtonProps) {
  const classes = ['glass-button', `glass-button--${variant}`, className].filter(Boolean).join(' ');
  return <button {...props} type={type} className={classes}>{children}</button>;
}
