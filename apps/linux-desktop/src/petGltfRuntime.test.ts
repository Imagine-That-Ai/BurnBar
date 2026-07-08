import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseGlb } from './petGltfRuntime.js';

describe('pet GLB runtime', () => {
  it('loads the bundled PetCompanion GLB with animation and mesh data', () => {
    const assetPath = path.join(process.cwd(), 'public/pets/kawaii-aurora-fox-actions.glb');
    const buffer = readFileSync(assetPath);
    const parsed = parseGlb(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength));
    expect(parsed.asset.version).toBe('2.0');
    expect(parsed.animations.length).toBeGreaterThan(0);
    expect(parsed.nodes.length).toBeGreaterThan(0);
    expect(parsed.points.length).toBeGreaterThan(20);
  });
});
