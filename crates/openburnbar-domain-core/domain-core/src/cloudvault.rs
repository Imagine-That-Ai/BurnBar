use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

const AAD_V2_PREFIX: &str = "OpenBurnBar-CloudVault-aad-v2";
const AAD_V1_PREFIX: &str = "OpenBurnBar-CloudVault-aad-v1";
const HMAC_SALT: &[u8] = b"OpenBurnBar-CloudVault-HMAC-Salt-v1";
const HMAC_INFO_PREFIX: &str = "OpenBurnBar-CloudVault-HMAC-v1";
const RECOVERY_SALT: &[u8] = b"OpenBurnBar-Recovery-Salt-v1";
const RECOVERY_WRAP_INFO: &[u8] = b"OpenBurnBar-Recovery-Wrap-v1";
const ESCROW_HKDF_INFO: &[u8] = b"OpenBurnBar-Escrow-v1";
pub const AES_GCM_NONCE_LENGTH: usize = 12;
pub const AES_GCM_TAG_LENGTH: usize = 16;
pub const P256_X963_PUBLIC_KEY_LENGTH: usize = 65;
pub const P256_ECDH_SHARED_SECRET_LENGTH: usize = 32;
pub const SESSION_BODY_HASH_VERSION: u32 = 2;
const MAX_BASE64_INPUT_BYTES: usize = 24 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudVaultHashPurpose {
    BlobIntegrity,
    SessionBody,
    SessionChunk,
    ProjectMemoryContent,
}

impl CloudVaultHashPurpose {
    fn label(self) -> &'static str {
        match self {
            Self::BlobIntegrity => "blob-integrity",
            Self::SessionBody => "session-body",
            Self::SessionChunk => "session-chunk",
            Self::ProjectMemoryContent => "project-memory-content",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CloudVaultError {
    #[error("cloud vault keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("cloud vault AAD parts must be non-empty and contain no controls or pipe")]
    InvalidAadPart,
    #[error("cloud vault AAD schema versions must be at least 2")]
    InvalidSchemaVersion,
    #[error("the envelope AAD does not match the expected context")]
    AadMismatch,
    #[error("legacy CloudVault v1 AAD is rejected")]
    LegacyAadRejected,
    #[error("the session body hash version is unsupported")]
    UnsupportedHashVersion,
    #[error("the CloudVault key derivation failed")]
    DerivationFailure,
    #[error("AES-256-GCM nonces must be exactly 12 bytes")]
    InvalidNonceLength,
    #[error("the AES-256-GCM combined box is too short")]
    InvalidCombinedLength,
    #[error("the AES-256-GCM authentication tag did not verify")]
    AuthenticationFailed,
    #[error("decrypted CloudVault text is not valid UTF-8")]
    InvalidUtf8,
    #[error("CloudVault Base64 must be canonical RFC 4648 standard encoding")]
    InvalidBase64,
    #[error("recovery keys must contain at least 20 normalized letters or numbers")]
    InvalidRecoveryKey,
    #[error("P-256 ECDH shared secrets must be exactly 32 bytes")]
    InvalidSharedSecretLength,
    #[error("P-256 public keys must be valid 65-byte uncompressed X9.63 points")]
    InvalidP256PublicKey,
    #[error("the P-256 escrow wire must contain a public key and AES-GCM combined box")]
    InvalidEscrowWireLength,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AesGcmDetachedBox {
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub tag: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecoveryWrappedVaultKey {
    pub combined: Vec<u8>,
    pub verification_hash: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EscrowWireParts {
    pub ephemeral_public_key: Vec<u8>,
    pub aes_gcm_combined: Vec<u8>,
}

impl AesGcmDetachedBox {
    pub fn combined(&self) -> Vec<u8> {
        let mut combined =
            Vec::with_capacity(self.nonce.len() + self.ciphertext.len() + self.tag.len());
        combined.extend_from_slice(&self.nonce);
        combined.extend_from_slice(&self.ciphertext);
        combined.extend_from_slice(&self.tag);
        combined
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CloudVaultAadContext {
    uid: String,
    collection: String,
    doc_id: String,
    field: String,
    schema_version: u32,
    purpose: String,
}

impl CloudVaultAadContext {
    pub fn new(
        uid: &str,
        collection: &str,
        doc_id: &str,
        field: &str,
        schema_version: u32,
        purpose: Option<&str>,
    ) -> Result<Self, CloudVaultError> {
        validate_aad_part(uid)?;
        validate_aad_part(collection)?;
        validate_aad_part(doc_id)?;
        validate_aad_part(field)?;
        if schema_version < 2 {
            return Err(CloudVaultError::InvalidSchemaVersion);
        }
        let purpose = purpose.unwrap_or(field);
        validate_aad_part(purpose)?;

        Ok(Self {
            uid: uid.to_owned(),
            collection: collection.to_owned(),
            doc_id: doc_id.to_owned(),
            field: field.to_owned(),
            schema_version,
            purpose: purpose.to_owned(),
        })
    }

    pub fn v2_string(&self) -> String {
        format!(
            "{AAD_V2_PREFIX}|{}|{}|{}|{}|{}|{}",
            self.uid, self.collection, self.doc_id, self.field, self.schema_version, self.purpose
        )
    }

    pub fn v1_string(&self) -> String {
        format!(
            "{AAD_V1_PREFIX}|{}|{}|{}|{}",
            self.uid, self.collection, self.doc_id, self.field
        )
    }

    pub fn resolve(
        &self,
        envelope_aad: &str,
        reject_legacy: bool,
    ) -> Result<Vec<u8>, CloudVaultError> {
        let v2 = self.v2_string();
        if envelope_aad == v2 {
            return Ok(v2.into_bytes());
        }

        let v1 = self.v1_string();
        if envelope_aad == v1 {
            return if reject_legacy {
                Err(CloudVaultError::LegacyAadRejected)
            } else {
                Ok(v1.into_bytes())
            };
        }

        Err(CloudVaultError::AadMismatch)
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    hex_lower(&Sha256::digest(data))
}

pub fn vault_key_id(key: &[u8]) -> Result<String, CloudVaultError> {
    require_vault_key(key)?;
    Ok(format!("v1_{}", &sha256_hex(key)[..32]))
}

pub fn keyed_hash_hex(
    data: &[u8],
    key: &[u8],
    purpose: CloudVaultHashPurpose,
) -> Result<String, CloudVaultError> {
    require_vault_key(key)?;
    let hkdf = Hkdf::<Sha256>::new(Some(HMAC_SALT), key);
    let mut derived_key = [0_u8; 32];
    let info = format!("{HMAC_INFO_PREFIX}|{}", purpose.label());
    if hkdf.expand(info.as_bytes(), &mut derived_key).is_err() {
        derived_key.zeroize();
        return Err(CloudVaultError::DerivationFailure);
    }

    let mut mac = match <Hmac<Sha256> as Mac>::new_from_slice(&derived_key) {
        Ok(mac) => mac,
        Err(_) => {
            derived_key.zeroize();
            return Err(CloudVaultError::DerivationFailure);
        }
    };
    derived_key.zeroize();
    mac.update(data);
    Ok(hex_lower(&mac.finalize().into_bytes()))
}

pub fn expected_session_body_hash(
    data: &[u8],
    key: &[u8],
    body_hash_version: u32,
) -> Result<String, CloudVaultError> {
    match body_hash_version {
        SESSION_BODY_HASH_VERSION => keyed_hash_hex(data, key, CloudVaultHashPurpose::SessionBody),
        0 | 1 => Ok(sha256_hex(data)),
        _ => Err(CloudVaultError::UnsupportedHashVersion),
    }
}

pub fn aes_gcm_seal_detached(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    aad: &[u8],
) -> Result<AesGcmDetachedBox, CloudVaultError> {
    require_vault_key(key)?;
    require_nonce(nonce)?;
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CloudVaultError::InvalidKeyLength)?;
    let mut ciphertext_and_tag = cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad,
            },
        )
        .map_err(|_| CloudVaultError::AuthenticationFailed)?;
    let tag = ciphertext_and_tag.split_off(ciphertext_and_tag.len() - AES_GCM_TAG_LENGTH);
    Ok(AesGcmDetachedBox {
        nonce: nonce.to_vec(),
        ciphertext: ciphertext_and_tag,
        tag,
    })
}

pub fn aes_gcm_seal_combined(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CloudVaultError> {
    Ok(aes_gcm_seal_detached(plaintext, key, nonce, aad)?.combined())
}

pub fn aes_gcm_open_detached(
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
    key: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CloudVaultError> {
    require_vault_key(key)?;
    require_nonce(nonce)?;
    if tag.len() != AES_GCM_TAG_LENGTH {
        return Err(CloudVaultError::InvalidCombinedLength);
    }
    let mut ciphertext_and_tag = Vec::with_capacity(ciphertext.len() + tag.len());
    ciphertext_and_tag.extend_from_slice(ciphertext);
    ciphertext_and_tag.extend_from_slice(tag);
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| CloudVaultError::InvalidKeyLength)?;
    cipher
        .decrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: &ciphertext_and_tag,
                aad,
            },
        )
        .map_err(|_| CloudVaultError::AuthenticationFailed)
}

pub fn aes_gcm_open_combined(
    combined: &[u8],
    key: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, CloudVaultError> {
    if combined.len() < AES_GCM_NONCE_LENGTH + AES_GCM_TAG_LENGTH {
        return Err(CloudVaultError::InvalidCombinedLength);
    }
    let ciphertext_end = combined.len() - AES_GCM_TAG_LENGTH;
    aes_gcm_open_detached(
        &combined[..AES_GCM_NONCE_LENGTH],
        &combined[AES_GCM_NONCE_LENGTH..ciphertext_end],
        &combined[ciphertext_end..],
        key,
        aad,
    )
}

pub fn aes_gcm_open_text_detached(
    nonce: &[u8],
    ciphertext: &[u8],
    tag: &[u8],
    key: &[u8],
    aad: &[u8],
) -> Result<String, CloudVaultError> {
    match String::from_utf8(aes_gcm_open_detached(nonce, ciphertext, tag, key, aad)?) {
        Ok(value) => Ok(value),
        Err(error) => {
            let mut plaintext = error.into_bytes();
            plaintext.zeroize();
            Err(CloudVaultError::InvalidUtf8)
        }
    }
}

pub fn base64_encode(data: &[u8]) -> String {
    BASE64_STANDARD.encode(data)
}

pub fn base64_decode_strict(value: &str) -> Result<Vec<u8>, CloudVaultError> {
    if value.len() > MAX_BASE64_INPUT_BYTES {
        return Err(CloudVaultError::InvalidBase64);
    }
    let decoded = BASE64_STANDARD
        .decode(value)
        .map_err(|_| CloudVaultError::InvalidBase64)?;
    if BASE64_STANDARD.encode(&decoded) != value {
        return Err(CloudVaultError::InvalidBase64);
    }
    Ok(decoded)
}

pub fn normalize_recovery_key(recovery_key: &str) -> Result<String, CloudVaultError> {
    let mut normalized: String = recovery_key
        .chars()
        .flat_map(char::to_uppercase)
        .filter(|character| character.is_alphanumeric())
        .collect();
    // Kotlin and C# historically measured the normalized key in UTF-16 code
    // units. Preserve keys those shipped clients already accepted, including
    // astral Unicode letters, while Rust becomes the canonical implementation.
    if normalized.encode_utf16().count() < 20 {
        normalized.zeroize();
        return Err(CloudVaultError::InvalidRecoveryKey);
    }
    Ok(normalized)
}

pub fn recovery_wrapping_key(recovery_key: &str) -> Result<[u8; 32], CloudVaultError> {
    let mut normalized = normalize_recovery_key(recovery_key)?;
    let result = derive_key_32(normalized.as_bytes(), RECOVERY_SALT, RECOVERY_WRAP_INFO);
    normalized.zeroize();
    result
}

pub fn recovery_verification_hash(recovery_key: &str) -> Result<String, CloudVaultError> {
    let mut key = recovery_wrapping_key(recovery_key)?;
    let result = sha256_hex(&key);
    key.zeroize();
    Ok(result)
}

pub fn recovery_wrap_vault_key(
    vault_key: &[u8],
    recovery_key: &str,
    nonce: &[u8],
) -> Result<RecoveryWrappedVaultKey, CloudVaultError> {
    require_vault_key(vault_key)?;
    let mut wrapping_key = recovery_wrapping_key(recovery_key)?;
    let combined = aes_gcm_seal_combined(vault_key, &wrapping_key, nonce, b"");
    let verification_hash = sha256_hex(&wrapping_key);
    wrapping_key.zeroize();
    Ok(RecoveryWrappedVaultKey {
        combined: combined?,
        verification_hash,
    })
}

pub fn recovery_open_vault_key(
    combined: &[u8],
    recovery_key: &str,
) -> Result<Vec<u8>, CloudVaultError> {
    let mut wrapping_key = recovery_wrapping_key(recovery_key)?;
    let opened = aes_gcm_open_combined(combined, &wrapping_key, b"");
    wrapping_key.zeroize();
    let vault_key = Zeroizing::new(opened?);
    require_vault_key(&vault_key)?;
    Ok(vault_key.to_vec())
}

pub fn validate_p256_x963_public_key(public_key: &[u8]) -> Result<(), CloudVaultError> {
    if public_key.len() != P256_X963_PUBLIC_KEY_LENGTH || public_key.first() != Some(&0x04) {
        return Err(CloudVaultError::InvalidP256PublicKey);
    }
    p256::PublicKey::from_sec1_bytes(public_key)
        .map(|_| ())
        .map_err(|_| CloudVaultError::InvalidP256PublicKey)
}

pub fn escrow_wrapping_key(shared_secret: &[u8]) -> Result<[u8; 32], CloudVaultError> {
    if shared_secret.len() != P256_ECDH_SHARED_SECRET_LENGTH {
        return Err(CloudVaultError::InvalidSharedSecretLength);
    }
    derive_key_32(shared_secret, b"", ESCROW_HKDF_INFO)
}

pub fn escrow_assemble_wire(
    ephemeral_public_key: &[u8],
    aes_gcm_combined: &[u8],
) -> Result<Vec<u8>, CloudVaultError> {
    validate_p256_x963_public_key(ephemeral_public_key)?;
    if aes_gcm_combined.len() < AES_GCM_NONCE_LENGTH + AES_GCM_TAG_LENGTH {
        return Err(CloudVaultError::InvalidEscrowWireLength);
    }
    let mut wire = Vec::with_capacity(ephemeral_public_key.len() + aes_gcm_combined.len());
    wire.extend_from_slice(ephemeral_public_key);
    wire.extend_from_slice(aes_gcm_combined);
    Ok(wire)
}

pub fn escrow_split_wire(wire: &[u8]) -> Result<EscrowWireParts, CloudVaultError> {
    if wire.len() < P256_X963_PUBLIC_KEY_LENGTH + AES_GCM_NONCE_LENGTH + AES_GCM_TAG_LENGTH {
        return Err(CloudVaultError::InvalidEscrowWireLength);
    }
    let (ephemeral_public_key, aes_gcm_combined) = wire.split_at(P256_X963_PUBLIC_KEY_LENGTH);
    validate_p256_x963_public_key(ephemeral_public_key)?;
    Ok(EscrowWireParts {
        ephemeral_public_key: ephemeral_public_key.to_vec(),
        aes_gcm_combined: aes_gcm_combined.to_vec(),
    })
}

pub fn escrow_seal(
    plaintext: &[u8],
    ephemeral_public_key: &[u8],
    shared_secret: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, CloudVaultError> {
    validate_p256_x963_public_key(ephemeral_public_key)?;
    let mut wrapping_key = escrow_wrapping_key(shared_secret)?;
    let combined = aes_gcm_seal_combined(plaintext, &wrapping_key, nonce, b"");
    wrapping_key.zeroize();
    escrow_assemble_wire(ephemeral_public_key, &combined?)
}

pub fn escrow_open(wire: &[u8], shared_secret: &[u8]) -> Result<Vec<u8>, CloudVaultError> {
    let parts = escrow_split_wire(wire)?;
    let mut wrapping_key = escrow_wrapping_key(shared_secret)?;
    let opened = aes_gcm_open_combined(&parts.aes_gcm_combined, &wrapping_key, b"");
    wrapping_key.zeroize();
    opened
}

fn derive_key_32(
    input_key_material: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; 32], CloudVaultError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), input_key_material);
    let mut derived_key = Zeroizing::new([0_u8; 32]);
    hkdf.expand(info, &mut *derived_key)
        .map_err(|_| CloudVaultError::DerivationFailure)?;
    Ok(*derived_key)
}

fn require_vault_key(key: &[u8]) -> Result<(), CloudVaultError> {
    if key.len() == 32 {
        Ok(())
    } else {
        Err(CloudVaultError::InvalidKeyLength)
    }
}

fn require_nonce(nonce: &[u8]) -> Result<(), CloudVaultError> {
    if nonce.len() == AES_GCM_NONCE_LENGTH {
        Ok(())
    } else {
        Err(CloudVaultError::InvalidNonceLength)
    }
}

fn validate_aad_part(value: &str) -> Result<(), CloudVaultError> {
    if value.is_empty()
        || value
            .chars()
            .any(|character| character <= '\u{1f}' || character == '\u{7f}' || character == '|')
    {
        Err(CloudVaultError::InvalidAadPart)
    } else {
        Ok(())
    }
}

fn hex_lower(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(char::from(DIGITS[usize::from(byte >> 4)]));
        output.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use std::io;

    const KEY_0: [u8; 32] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e,
        0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
        0x1e, 0x1f,
    ];
    const DATA: &[u8] = b"the quick brown fox jumps over the lazy dog";

    fn fixture() -> Result<Value, serde_json::Error> {
        serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json"
        ))
    }

    fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str, io::Error> {
        value[key]
            .as_str()
            .ok_or_else(|| io::Error::other(format!("fixture field {key} must be a string")))
    }

    fn decode_hex(value: &str) -> Result<Vec<u8>, io::Error> {
        if !value.len().is_multiple_of(2) {
            return Err(io::Error::other("hex fixture must have an even length"));
        }
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let text = std::str::from_utf8(pair)
                    .map_err(|_| io::Error::other("hex fixture must be ASCII"))?;
                u8::from_str_radix(text, 16)
                    .map_err(|_| io::Error::other("hex fixture contains a non-hex digit"))
            })
            .collect()
    }

    fn context() -> Result<CloudVaultAadContext, CloudVaultError> {
        CloudVaultAadContext::new("user_alice", "cloudSessions", "doc_123", "title", 2, None)
    }

    #[test]
    fn aad_matches_all_existing_platform_contracts() -> Result<(), CloudVaultError> {
        let context = context()?;
        assert_eq!(
            context.v2_string(),
            "OpenBurnBar-CloudVault-aad-v2|user_alice|cloudSessions|doc_123|title|2|title"
        );
        assert_eq!(
            context.v1_string(),
            "OpenBurnBar-CloudVault-aad-v1|user_alice|cloudSessions|doc_123|title"
        );
        assert_eq!(
            context.resolve(&context.v2_string(), true)?,
            context.v2_string().as_bytes()
        );
        assert_eq!(
            context.resolve(&context.v1_string(), false)?,
            context.v1_string().as_bytes()
        );
        assert_eq!(
            context.resolve(&context.v1_string(), true),
            Err(CloudVaultError::LegacyAadRejected)
        );
        assert_eq!(
            context.resolve("wrong", false),
            Err(CloudVaultError::AadMismatch)
        );
        Ok(())
    }

    #[test]
    fn aad_validation_rejects_ambiguous_or_legacy_contexts() {
        for invalid in ["", "has|pipe", "line\nbreak", "delete\u{7f}"] {
            assert_eq!(
                CloudVaultAadContext::new(invalid, "c", "d", "f", 2, None),
                Err(CloudVaultError::InvalidAadPart)
            );
        }
        assert_eq!(
            CloudVaultAadContext::new("u", "c", "d", "f", 1, None),
            Err(CloudVaultError::InvalidSchemaVersion)
        );
    }

    #[test]
    fn hashes_match_committed_windows_kats() -> Result<(), CloudVaultError> {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(vault_key_id(&KEY_0)?, "v1_630dcd2966c4336691125448bbb25b4f");
        let vectors = [
            (
                CloudVaultHashPurpose::BlobIntegrity,
                "bc634e0b46beab56ba01e1a234d2f293d009d29e4dec54e35b853d732b5f463f",
            ),
            (
                CloudVaultHashPurpose::SessionBody,
                "24c3844a66a803df5cfaf2b64eec2e841d88cc71cfeb07d2fa1be1435ca551ea",
            ),
        ];
        for (purpose, expected) in vectors {
            assert_eq!(keyed_hash_hex(DATA, &KEY_0, purpose)?, expected);
        }
        Ok(())
    }

    #[test]
    fn session_body_hash_versions_preserve_legacy_behavior() -> Result<(), CloudVaultError> {
        assert_eq!(
            expected_session_body_hash(DATA, &KEY_0, 2)?,
            keyed_hash_hex(DATA, &KEY_0, CloudVaultHashPurpose::SessionBody)?
        );
        for version in [0, 1] {
            assert_eq!(
                expected_session_body_hash(DATA, &KEY_0, version)?,
                sha256_hex(DATA)
            );
        }
        assert_eq!(
            expected_session_body_hash(DATA, &KEY_0, 3),
            Err(CloudVaultError::UnsupportedHashVersion)
        );
        Ok(())
    }

    #[test]
    fn all_keyed_operations_reject_non_vault_keys() {
        assert_eq!(
            vault_key_id(&[0; 31]),
            Err(CloudVaultError::InvalidKeyLength)
        );
        assert_eq!(
            keyed_hash_hex(DATA, &[0; 33], CloudVaultHashPurpose::SessionBody),
            Err(CloudVaultError::InvalidKeyLength)
        );
        assert_eq!(
            expected_session_body_hash(DATA, &[0; 31], 2),
            Err(CloudVaultError::InvalidKeyLength)
        );
    }

    #[test]
    fn aes_gcm_matches_webcrypto_and_accepts_empty_plaintext() -> Result<(), CloudVaultError> {
        let key = [0_u8; 32];
        let nonce = [0_u8; 12];
        let empty = aes_gcm_seal_detached(b"", &key, &nonce, b"")?;
        assert!(empty.ciphertext.is_empty());
        assert_eq!(hex_lower(&empty.tag), "530f8afbc74536b9a963b4f1c4cb738b");
        assert_eq!(aes_gcm_open_combined(&empty.combined(), &key, b"")?, b"");

        let aad = b"OpenBurnBar-CloudVault-aad-v2|user|sessions|doc|body|2|body";
        let sealed = aes_gcm_seal_detached(b"OpenBurnBar", &key, &nonce, aad)?;
        assert_eq!(hex_lower(&sealed.ciphertext), "81d725530f151900452fb7");
        assert_eq!(hex_lower(&sealed.tag), "e9e30933fbcf60439ddc46e286803403");
        assert_eq!(
            aes_gcm_open_text_detached(&sealed.nonce, &sealed.ciphertext, &sealed.tag, &key, aad)?,
            "OpenBurnBar"
        );
        Ok(())
    }

    #[test]
    fn aes_gcm_and_wire_decoders_fail_closed() -> Result<(), CloudVaultError> {
        let key = [0_u8; 32];
        let nonce = [0_u8; 12];
        let mut sealed = aes_gcm_seal_combined(b"text", &key, &nonce, b"aad")?;
        sealed[12] ^= 1;
        assert_eq!(
            aes_gcm_open_combined(&sealed, &key, b"aad"),
            Err(CloudVaultError::AuthenticationFailed)
        );
        assert_eq!(
            aes_gcm_open_combined(&[0_u8; 27], &key, b""),
            Err(CloudVaultError::InvalidCombinedLength)
        );
        assert_eq!(
            aes_gcm_seal_combined(b"", &key, &[0_u8; 11], b""),
            Err(CloudVaultError::InvalidNonceLength)
        );
        assert_eq!(base64_decode_strict("AA==")?, vec![0]);
        for invalid in ["AA", "AB==", " AA==", "AA==\n"] {
            assert_eq!(
                base64_decode_strict(invalid),
                Err(CloudVaultError::InvalidBase64)
            );
        }
        assert_eq!(
            base64_decode_strict(&"A".repeat(MAX_BASE64_INPUT_BYTES + 1)),
            Err(CloudVaultError::InvalidBase64)
        );
        let invalid_utf8 = aes_gcm_seal_detached(&[0xff], &key, &nonce, b"")?;
        assert_eq!(
            aes_gcm_open_text_detached(
                &invalid_utf8.nonce,
                &invalid_utf8.ciphertext,
                &invalid_utf8.tag,
                &key,
                b""
            ),
            Err(CloudVaultError::InvalidUtf8)
        );
        Ok(())
    }

    #[test]
    fn recovery_contract_matches_canonical_fixture_and_fails_closed(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        let vector = &fixture["recovery"];
        let formatted_key = required_string(vector, "formattedKey")?;
        let vault_key = decode_hex(required_string(vector, "vaultKeyHex")?)?;
        let nonce = decode_hex(required_string(vector, "nonceHex")?)?;

        assert_eq!(
            normalize_recovery_key(formatted_key)?,
            required_string(vector, "normalizedKey")?
        );
        assert_eq!(
            hex_lower(&recovery_wrapping_key(formatted_key)?),
            required_string(vector, "wrappingKeyHex")?
        );
        assert_eq!(
            recovery_verification_hash(formatted_key)?,
            required_string(vector, "verificationHash")?
        );
        assert_eq!(
            normalize_recovery_key(required_string(vector, "unicodeFormattedKey")?)?,
            required_string(vector, "unicodeNormalizedKey")?
        );
        assert_eq!(
            hex_lower(&recovery_wrapping_key(required_string(
                vector,
                "unicodeFormattedKey"
            )?)?),
            required_string(vector, "unicodeWrappingKeyHex")?
        );

        let wrapped = recovery_wrap_vault_key(&vault_key, formatted_key, &nonce)?;
        assert_eq!(
            hex_lower(&wrapped.combined),
            required_string(vector, "combinedHex")?
        );
        assert_eq!(
            wrapped.verification_hash,
            required_string(vector, "verificationHash")?
        );
        assert_eq!(
            recovery_open_vault_key(&wrapped.combined, formatted_key)?,
            vault_key
        );

        assert_eq!(
            normalize_recovery_key("too-short"),
            Err(CloudVaultError::InvalidRecoveryKey)
        );
        assert_eq!(
            recovery_open_vault_key(&wrapped.combined, "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ"),
            Err(CloudVaultError::AuthenticationFailed)
        );
        assert_eq!(
            recovery_wrap_vault_key(&[0_u8; 31], formatted_key, &nonce),
            Err(CloudVaultError::InvalidKeyLength)
        );
        let mut wrapping_key = recovery_wrapping_key(formatted_key)?;
        let authenticated_short_key =
            aes_gcm_seal_combined(&[0x5a; 31], &wrapping_key, &nonce, b"")?;
        wrapping_key.zeroize();
        assert_eq!(
            recovery_open_vault_key(&authenticated_short_key, formatted_key),
            Err(CloudVaultError::InvalidKeyLength)
        );
        Ok(())
    }

    #[test]
    fn p256_escrow_contract_matches_canonical_fixture_and_accepts_empty_plaintext(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        let vector = &fixture["p256Escrow"];
        let public_key = decode_hex(required_string(vector, "ephemeralPublicKeyHex")?)?;
        let shared_secret = decode_hex(required_string(vector, "sharedSecretHex")?)?;
        let nonce = decode_hex(required_string(vector, "nonceHex")?)?;
        let plaintext = decode_hex(required_string(vector, "plaintextHex")?)?;

        validate_p256_x963_public_key(&public_key)?;
        assert_eq!(
            hex_lower(&escrow_wrapping_key(&shared_secret)?),
            required_string(vector, "wrappingKeyHex")?
        );
        let wire = escrow_seal(&plaintext, &public_key, &shared_secret, &nonce)?;
        assert_eq!(hex_lower(&wire), required_string(vector, "wireHex")?);
        assert_eq!(escrow_open(&wire, &shared_secret)?, plaintext);

        let parts = escrow_split_wire(&wire)?;
        assert_eq!(parts.ephemeral_public_key, public_key);
        assert_eq!(
            escrow_assemble_wire(&public_key, &parts.aes_gcm_combined)?,
            wire
        );

        let empty_wire = escrow_seal(b"", &public_key, &shared_secret, &nonce)?;
        assert_eq!(
            hex_lower(&empty_wire),
            required_string(vector, "emptyWireHex")?
        );
        assert_eq!(escrow_open(&empty_wire, &shared_secret)?, b"");
        Ok(())
    }

    #[test]
    fn p256_escrow_rejects_malformed_points_wires_and_secrets(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        let vector = &fixture["p256Escrow"];
        let public_key = decode_hex(required_string(vector, "ephemeralPublicKeyHex")?)?;
        let shared_secret = decode_hex(required_string(vector, "sharedSecretHex")?)?;
        let nonce = decode_hex(required_string(vector, "nonceHex")?)?;

        let mut compressed = public_key[1..34].to_vec();
        compressed.insert(0, 0x02);
        assert_eq!(
            validate_p256_x963_public_key(&compressed),
            Err(CloudVaultError::InvalidP256PublicKey)
        );
        let mut off_curve = public_key.clone();
        if let Some(last) = off_curve.last_mut() {
            *last ^= 1;
        }
        assert_eq!(
            validate_p256_x963_public_key(&off_curve),
            Err(CloudVaultError::InvalidP256PublicKey)
        );
        assert_eq!(
            escrow_wrapping_key(&[0_u8; 31]),
            Err(CloudVaultError::InvalidSharedSecretLength)
        );
        assert_eq!(
            escrow_split_wire(&[0_u8; 92]),
            Err(CloudVaultError::InvalidEscrowWireLength)
        );

        let wire = escrow_seal(b"payload", &public_key, &shared_secret, &nonce)?;
        let mut wrong_secret = shared_secret.clone();
        wrong_secret[0] ^= 1;
        assert_eq!(
            escrow_open(&wire, &wrong_secret),
            Err(CloudVaultError::AuthenticationFailed)
        );
        let mut tampered = wire;
        if let Some(last) = tampered.last_mut() {
            *last ^= 1;
        }
        assert_eq!(
            escrow_open(&tampered, &shared_secret),
            Err(CloudVaultError::AuthenticationFailed)
        );
        Ok(())
    }

    #[test]
    fn aes_roundtrip_and_tamper_properties_hold_for_generated_inputs() -> Result<(), CloudVaultError>
    {
        let key = [0x5a; 32];
        for length in 0..512_usize {
            let plaintext = (0..length)
                .map(|index| (index.wrapping_mul(31).wrapping_add(length)) as u8)
                .collect::<Vec<_>>();
            let mut nonce = [0_u8; 12];
            nonce[4..].copy_from_slice(&(length as u64).to_be_bytes());
            let aad = format!("property|{length}");
            let sealed = aes_gcm_seal_combined(&plaintext, &key, &nonce, aad.as_bytes())?;
            assert_eq!(
                aes_gcm_open_combined(&sealed, &key, aad.as_bytes())?,
                plaintext
            );
            let mut tampered = sealed;
            let last = tampered
                .len()
                .checked_sub(1)
                .ok_or(CloudVaultError::InvalidCombinedLength)?;
            tampered[last] ^= 1;
            assert_eq!(
                aes_gcm_open_combined(&tampered, &key, aad.as_bytes()),
                Err(CloudVaultError::AuthenticationFailed)
            );
        }
        Ok(())
    }

    #[test]
    fn canonical_fixture_is_executable_contract() -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        assert_eq!(
            fixture["schema"],
            "openburnbar.domain-core.cloudvault.deterministic.v1"
        );

        for vector in fixture["aad"]
            .as_array()
            .ok_or_else(|| io::Error::other("aad vectors must be an array"))?
        {
            let schema_version = vector["schemaVersion"]
                .as_u64()
                .and_then(|value| u32::try_from(value).ok())
                .ok_or_else(|| io::Error::other("schemaVersion must be a u32"))?;
            let context = CloudVaultAadContext::new(
                required_string(vector, "uid")?,
                required_string(vector, "collection")?,
                required_string(vector, "docID")?,
                required_string(vector, "field")?,
                schema_version,
                Some(required_string(vector, "purpose")?),
            )?;
            assert_eq!(context.v1_string(), required_string(vector, "v1")?);
            assert_eq!(context.v2_string(), required_string(vector, "v2")?);
        }

        for vector in fixture["sha256"]
            .as_array()
            .ok_or_else(|| io::Error::other("sha256 vectors must be an array"))?
        {
            let data = decode_hex(required_string(vector, "dataHex")?)?;
            assert_eq!(sha256_hex(&data), required_string(vector, "hex")?);
        }

        for vector in fixture["vaultKeyID"]
            .as_array()
            .ok_or_else(|| io::Error::other("vaultKeyID vectors must be an array"))?
        {
            let key = decode_hex(required_string(vector, "keyHex")?)?;
            assert_eq!(vault_key_id(&key)?, required_string(vector, "value")?);
        }

        for vector in fixture["keyedHashes"]
            .as_array()
            .ok_or_else(|| io::Error::other("keyed hash vectors must be an array"))?
        {
            let purpose = match required_string(vector, "purpose")? {
                "blob-integrity" => CloudVaultHashPurpose::BlobIntegrity,
                "session-body" => CloudVaultHashPurpose::SessionBody,
                "session-chunk" => CloudVaultHashPurpose::SessionChunk,
                "project-memory-content" => CloudVaultHashPurpose::ProjectMemoryContent,
                _ => return Err(io::Error::other("unknown keyed hash purpose").into()),
            };
            let key = decode_hex(required_string(vector, "keyHex")?)?;
            let data = decode_hex(required_string(vector, "dataHex")?)?;
            assert_eq!(
                keyed_hash_hex(&data, &key, purpose)?,
                required_string(vector, "hex")?
            );
        }

        let key = decode_hex(required_string(&fixture["keyedHashes"][1], "keyHex")?)?;
        for vector in fixture["expectedSessionBodyHash"]
            .as_array()
            .ok_or_else(|| io::Error::other("body hash vectors must be an array"))?
        {
            let version = vector["bodyHashVersion"]
                .as_u64()
                .and_then(|value| u32::try_from(value).ok())
                .ok_or_else(|| io::Error::other("bodyHashVersion must be a u32"))?;
            assert_eq!(
                expected_session_body_hash(DATA, &key, version)?,
                required_string(vector, "hex")?
            );
        }
        for vector in fixture["aesGcm"]
            .as_array()
            .ok_or_else(|| io::Error::other("AES-GCM vectors must be an array"))?
        {
            let key = decode_hex(required_string(vector, "keyHex")?)?;
            let nonce = decode_hex(required_string(vector, "nonceHex")?)?;
            let plaintext = decode_hex(required_string(vector, "plaintextHex")?)?;
            let aad = decode_hex(required_string(vector, "aadHex")?)?;
            let sealed = aes_gcm_seal_detached(&plaintext, &key, &nonce, &aad)?;
            assert_eq!(
                hex_lower(&sealed.ciphertext),
                required_string(vector, "ciphertextHex")?
            );
            assert_eq!(hex_lower(&sealed.tag), required_string(vector, "tagHex")?);
            assert_eq!(
                base64_encode(&sealed.combined()),
                required_string(vector, "combinedBase64")?
            );
            assert_eq!(
                aes_gcm_open_combined(&sealed.combined(), &key, &aad)?,
                plaintext
            );
        }
        Ok(())
    }
}
