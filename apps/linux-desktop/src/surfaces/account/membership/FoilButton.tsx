import type { ButtonHTMLAttributes, ReactNode } from 'react';

export function FoilButton({
  children,
  variant = 'primary',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & {
  children: ReactNode;
  variant?: 'primary' | 'secondary';
}) {
  return (
    <button
      type="button"
      className={`membership-foil-button membership-foil-button--${variant} ${className}`.trim()}
      {...props}
    >
      {children}
    </button>
  );
}
