import { afterEach, describe, expect, it, vi } from 'vitest';
import { readPetAsset } from './petAssets.js';
import { DEFAULT_PET_GLB } from './petCatalog.js';
import type { LinuxShellBridge } from './tauriBridge.js';

function bridgeWith(petAssetRead: LinuxShellBridge['petAssetRead']): LinuxShellBridge {
  return { petAssetRead } as LinuxShellBridge;
}

function assetResponse(glbName: string, payload: string) {
  return {
    schemaVersion: 1,
    glbName,
    byteLength: payload.length,
    sha256: 'test',
    dataBase64: btoa(payload)
  };
}

describe('readPetAsset', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('rejects unsafe GLB names before touching the bridge or network', async () => {
    const petAssetRead = vi.fn();
    await expect(readPetAsset(bridgeWith(petAssetRead), '../escape.glb')).rejects.toThrow(/invalid/);
    expect(petAssetRead).not.toHaveBeenCalled();
  });

  it('uses the bridge command when the host implements it', async () => {
    const petAssetRead = vi.fn().mockResolvedValue(assetResponse('ada-lovelace-actions.glb', 'GLB0'));
    const buffer = await readPetAsset(bridgeWith(petAssetRead), 'ada-lovelace-actions.glb');
    expect(new TextDecoder().decode(buffer)).toBe('GLB0');
    expect(petAssetRead).toHaveBeenCalledWith('ada-lovelace-actions.glb');
  });

  it('falls back to the committed default asset when a shared host answers capability-absent', async () => {
    const petAssetRead = vi.fn().mockRejectedValue(new Error('not implemented on Windows: pet_asset_read'));
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      arrayBuffer: async () => new ArrayBuffer(16)
    });
    vi.stubGlobal('fetch', fetchMock);

    const buffer = await readPetAsset(bridgeWith(petAssetRead), DEFAULT_PET_GLB);
    expect(buffer.byteLength).toBe(16);
    expect(fetchMock).toHaveBeenCalledWith(`/pets/${encodeURIComponent(DEFAULT_PET_GLB)}`);
  });

  it('still refuses non-default catalog assets on capability-absent hosts', async () => {
    const petAssetRead = vi.fn().mockRejectedValue(new Error('not implemented on Windows: pet_asset_read'));
    await expect(readPetAsset(bridgeWith(petAssetRead), 'ada-lovelace-actions.glb')).rejects.toThrow(
      /packaged Linux shell/
    );
  });

  it('rethrows real bridge failures instead of masking them as fallbacks', async () => {
    const petAssetRead = vi.fn().mockRejectedValue(new Error('disk read failed'));
    await expect(readPetAsset(bridgeWith(petAssetRead), DEFAULT_PET_GLB)).rejects.toThrow(/disk read failed/);
  });

  it('validates that the bridge response matches the requested asset', async () => {
    const petAssetRead = vi.fn().mockResolvedValue(assetResponse('other.glb', 'GLB0'));
    await expect(readPetAsset(bridgeWith(petAssetRead), DEFAULT_PET_GLB)).rejects.toThrow(/does not match/);
  });
});
