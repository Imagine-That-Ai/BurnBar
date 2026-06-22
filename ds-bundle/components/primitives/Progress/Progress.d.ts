import * as React from 'react';

/**
 * Progress — from @openburnbar/console@0.1.0.
 */
export interface ProgressProps {
/** Fill fraction, 0..1. Values > 1 clamp the bar to full and tint it crimson (over-quota). */
value: number;
/** CSS custom-property name for the fill colour (default "--color-brass-core", the accent). */
fillVar?: string;
className?: string;
}

export declare const Progress: React.ComponentType<ProgressProps>;
