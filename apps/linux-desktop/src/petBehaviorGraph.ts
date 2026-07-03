export type PetBehaviorNode = {
  id: string;
  label: string;
  kind: 'idle' | 'react' | 'tier-limit';
  next: string[];
};

export type PetBehaviorGraph = {
  gltfAsset: string;
  nodes: PetBehaviorNode[];
};

export function buildPetBehaviorGraph(tier: 'overlay-pass-through' | 'draggable-contained'): PetBehaviorGraph {
  const tierLimit = tier === 'draggable-contained' ? 'tier-gnome-contained' : 'tier-overlay-ok';
  return {
    gltfAsset: '/pets/kawaii-aurora-fox-actions.glb',
    nodes: [
      { id: 'idle-bob', label: 'Idle bob', kind: 'idle', next: ['react-wave', tierLimit] },
      { id: 'react-wave', label: 'React wave', kind: 'react', next: ['idle-bob'] },
      {
        id: tierLimit,
        label: tier === 'draggable-contained' ? 'GNOME: no click-through' : 'Overlay pass-through',
        kind: 'tier-limit',
        next: ['idle-bob']
      }
    ]
  };
}
