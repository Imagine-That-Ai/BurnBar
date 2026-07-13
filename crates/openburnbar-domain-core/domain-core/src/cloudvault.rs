use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use zeroize::Zeroize;

const AAD_V2_PREFIX: &str = "OpenBurnBar-CloudVault-aad-v2";
const AAD_V1_PREFIX: &str = "OpenBurnBar-CloudVault-aad-v1";
const HMAC_SALT: &[u8] = b"OpenBurnBar-CloudVault-HMAC-Salt-v1";
const HMAC_INFO_PREFIX: &str = "OpenBurnBar-CloudVault-HMAC-v1";
pub const SESSION_BODY_HASH_VERSION: u32 = 2;

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

    let mut mac = match Hmac::<Sha256>::new_from_slice(&derived_key) {
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

fn require_vault_key(key: &[u8]) -> Result<(), CloudVaultError> {
    if key.len() == 32 {
        Ok(())
    } else {
        Err(CloudVaultError::InvalidKeyLength)
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
        Ok(())
    }
}
