import * as React from 'react';

/**
 * TierGlyph — from @openburnbar/console@0.1.0.
 */
export interface TierGlyphProps {
/** Which encryption crest to draw: shield (end-to-end), lock (zero-access), or eye (server-readable). */
glyph: "shield" | "lock" | "eye";
/** CSS custom-property name the glyph is lit in, e.g. "--color-tier-end-to-end". */
colorVar: string;
/** Square canvas size in pixels (default 34). */
size?: number;
/** Accessible label (defaults to "<glyph> tier mark"). */
label?: string;
}

export declare const TierGlyph: React.ComponentType<TierGlyphProps>;
