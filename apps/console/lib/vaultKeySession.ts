let vaultKeyBytes: Uint8Array | null = null;
let vaultCryptoKey: CryptoKey | null = null;

export function setConsoleVaultKey(vaultKey: CryptoKey, rawVaultKey: Uint8Array) {
  vaultCryptoKey = vaultKey;
  vaultKeyBytes = new Uint8Array(rawVaultKey);
}

export function getConsoleVaultKeyBytes(): Uint8Array | null {
  return vaultKeyBytes ? new Uint8Array(vaultKeyBytes) : null;
}

export function getConsoleVaultCryptoKey(): CryptoKey | null {
  return vaultCryptoKey;
}
