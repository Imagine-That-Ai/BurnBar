import * as React from 'react';

/**
 * Card — from @openburnbar/console@0.1.0.
 */
export interface CardProps {
/** Card body. Compose with the compound parts exported from the same module: `CardHeader`, `CardTitle`, `CardDescription`, `CardContent`. */
children?: React.ReactNode;
className?: string;
/** All native `<div>` attributes are also accepted. */
}

export declare const Card: React.ComponentType<CardProps>;
