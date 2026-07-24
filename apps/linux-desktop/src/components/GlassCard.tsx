import type { HTMLAttributes, ReactNode } from 'react';

export type GlassCardProps = HTMLAttributes<HTMLElement> & {
  children?: ReactNode;
  /** Mirrors macOS GlassCard's interactive press/hover behavior. */
  interactive?: boolean;
  /** Mirrors the compact embedded card variant used inside grouped surfaces. */
  embedded?: boolean;
  as?: 'div' | 'section' | 'article';
};

/** Typed Linux counterpart to macOS GlassCard. */
export function GlassCard({
  children,
  className = '',
  interactive = false,
  embedded = false,
  as = 'div',
  ...props
}: GlassCardProps) {
  const Element = as;
  const classes = [
    'card',
    'glass-card',
    interactive ? 'glass-card--interactive' : '',
    embedded ? 'glass-card--embedded' : '',
    className
  ].filter(Boolean).join(' ');

  return <Element {...props} className={classes}>{children}</Element>;
}
