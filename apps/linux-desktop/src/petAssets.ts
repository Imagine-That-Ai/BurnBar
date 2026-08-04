import type { LinuxShellBridge, PetAssetResponse } from './tauriBridge.js';
import { isCapabilityAbsentError } from './tauriBridgePlatformDecoders.js';
import { DEFAULT_PET_GLB } from './petCatalog.js';

const SAFE_GLB = /^[A-Za-z0-9][A-Za-z0-9._-]*\.glb$/u;

function decodeBase64(value: string): ArrayBuffer {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function validateAssetResponse(requestedGLB: string, response: PetAssetResponse): ArrayBuffer {
  if (response.glbName !== requestedGLB) throw new Error('Pet asset response name does not match the request.');
  const buffer = decodeBase64(response.dataBase64);
  if (buffer.byteLength !== response.byteLength) throw new Error('Pet asset response length is invalid.');
  return buffer;
}

export async function readPetAsset(bridge: LinuxShellBridge | null, glbName: string): Promise<ArrayBuffer> {
  if (!SAFE_GLB.test(glbName)) throw new Error('Pet asset name is invalid.');
  if (bridge?.petAssetRead) {
    try {
      return validateAssetResponse(glbName, await bridge.petAssetRead(glbName));
    } catch (error) {
      // Shared hosts (Windows WebView2) expose the bridge surface but answer
      // pet_asset_read with a capability-absent error. Degrade to the committed
      // default asset instead of failing the whole companion runtime.
      if (!isCapabilityAbsentError(error)) throw error;
    }
  }

  // Browser preview and fixture mode retain the one small committed asset so
  // the route remains inspectable without pretending that all packaged model
  // resources are available outside the Tauri shell.
  if (glbName !== DEFAULT_PET_GLB) {
    throw new Error('The full pet catalog requires the packaged Linux shell.');
  }
  const response = await fetch(`/pets/${encodeURIComponent(glbName)}`);
  if (!response.ok) throw new Error(`Unable to load pet asset: ${response.status}`);
  return response.arrayBuffer();
}
