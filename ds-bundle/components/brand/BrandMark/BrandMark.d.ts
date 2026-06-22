import * as React from 'react';

/**
 * BrandMark — from @openburnbar/console@0.1.0.
 */
export interface BrandMarkProps {
/** Square size of the framed mark, in pixels (default 92). Plays /brand/burnbar-mark.mp4 when present, else falls back to the static logo. */
size?: number;
}

export declare const BrandMark: React.ComponentType<BrandMarkProps>;
