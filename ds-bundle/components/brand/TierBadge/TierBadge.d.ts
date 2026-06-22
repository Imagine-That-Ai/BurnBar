import * as React from 'react';

/**
 * TierBadge — from @openburnbar/console@0.1.0.
 */
export interface TierBadgeProps {
/** Encryption tier; selects the icon (eye/shield/lock) and the member-facing copy. */
tier: "server_readable" | "zero_access" | "end_to_end";
}

export declare const TierBadge: React.ComponentType<TierBadgeProps>;
