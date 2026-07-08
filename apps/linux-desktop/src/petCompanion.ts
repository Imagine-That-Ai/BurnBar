export type PetTier = 'overlay-pass-through' | 'draggable-contained';
export function detectPetTierFromEnv(env: Record<string, string | undefined> = {}): {
  tier: PetTier;
  compositor: string;
  message: string;
} {
  const session = (env.XDG_SESSION_TYPE ?? 'unknown').toLowerCase();
  const desktop = (env.XDG_CURRENT_DESKTOP ?? 'unknown').toLowerCase();
  const compositor = `${desktop}/${session}`;
  const gnomeWayland = desktop.includes('gnome') && session.includes('wayland');
  if (gnomeWayland) {
    return {
      tier: 'draggable-contained',
      compositor,
      message:
        'GNOME Wayland does not expose global click-through overlays. Pet runs in a draggable contained tier with explicit copy.'
    };
  }
  return {
    tier: 'overlay-pass-through',
    compositor,
    message:
      'Compositor reports overlay support; pet uses always-on-top pass-through when the window manager allows it.'
  };
}