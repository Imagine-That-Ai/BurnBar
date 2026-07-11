import { KeyManagementServiceClient, protos } from "@google-cloud/kms";
import type { VerdictSigner } from "./ports.js";

type KmsClient = Pick<KeyManagementServiceClient, "asymmetricSign" | "getCryptoKeyVersion">;

export function crc32c(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (crc & 1 ? 0x82f63b78 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

export class KmsEd25519Signer implements VerdictSigner {
  readonly keyId: string;
  private readiness: Promise<void> | undefined;
  constructor(private readonly keyVersionName: string, private readonly client: KmsClient = new KeyManagementServiceClient()) {
    this.keyId = keyVersionName;
  }
  async sign(data: Buffer): Promise<Buffer> {
    await this.ready();
    const checksum = crc32c(data);
    const [response] = await this.client.asymmetricSign({ name: this.keyVersionName, data, dataCrc32c: { value: checksum } });
    if (response.verifiedDataCrc32c !== true || response.name !== this.keyVersionName || response.signature === undefined || response.signature === null || typeof response.signature === "string") {
      throw new Error("KMS signing integrity validation failed");
    }
    const signature = Buffer.from(response.signature);
    const responseChecksum = response.signatureCrc32c?.value;
    if (signature.byteLength !== 64 || responseChecksum === undefined || responseChecksum === null || Number(responseChecksum.toString()) !== crc32c(signature)) {
      throw new Error("KMS signature integrity validation failed");
    }
    return signature;
  }

  private async ready(): Promise<void> {
    const existing = this.readiness;
    if (existing !== undefined) return existing;
    const pending = this.validateKeyVersion();
    this.readiness = pending;
    try {
      await pending;
    } catch (error) {
      if (this.readiness === pending) this.readiness = undefined;
      throw error;
    }
  }

  private async validateKeyVersion(): Promise<void> {
    const [version] = await this.client.getCryptoKeyVersion({ name: this.keyVersionName });
    if (version.name !== this.keyVersionName
      || version.state !== protos.google.cloud.kms.v1.CryptoKeyVersion.CryptoKeyVersionState.ENABLED
      || version.algorithm !== protos.google.cloud.kms.v1.CryptoKeyVersion.CryptoKeyVersionAlgorithm.EC_SIGN_ED25519) {
      throw new Error("KMS key version must be enabled Ed25519");
    }
  }
}
