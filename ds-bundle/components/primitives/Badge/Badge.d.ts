import * as React from 'react';

/**
 * Badge — from @openburnbar/console@0.1.0.
 */
export interface BadgeProps {
/** Encryption-tier identity; selects the colour. `neutral` (default) is a plain grey pill. */
tier?: "server_readable" | "zero_access" | "end_to_end" | "neutral";
/** Badge content — a short label, optionally with a leading icon. */
children?: React.ReactNode;
className?: string;
title?: string;
}

export declare const Badge: React.ComponentType<BadgeProps>;
