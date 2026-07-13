use openburnbar_domain_core::cloudvault::{
    self, CloudVaultAadContext, CloudVaultError, CloudVaultHashPurpose as CoreHashPurpose,
};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudVaultHashPurpose {
    BlobIntegrity,
    SessionBody,
    SessionChunk,
    ProjectMemoryContent,
}

impl From<CloudVaultHashPurpose> for CoreHashPurpose {
    fn from(value: CloudVaultHashPurpose) -> Self {
        match value {
            CloudVaultHashPurpose::BlobIntegrity => Self::BlobIntegrity,
            CloudVaultHashPurpose::SessionBody => Self::SessionBody,
            CloudVaultHashPurpose::SessionChunk => Self::SessionChunk,
            CloudVaultHashPurpose::ProjectMemoryContent => Self::ProjectMemoryContent,
        }
    }
}

#[wasm_bindgen(js_name = cloudVaultAadV2)]
pub fn cloud_vault_aad_v2(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(uid, collection, doc_id, field, schema_version, purpose)?.v2_string())
}

#[wasm_bindgen(js_name = cloudVaultAadV1)]
pub fn cloud_vault_aad_v1(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(uid, collection, doc_id, field, schema_version, purpose)?.v1_string())
}

#[wasm_bindgen(js_name = cloudVaultSha256Hex)]
pub fn cloud_vault_sha256_hex(data: &[u8]) -> String {
    cloudvault::sha256_hex(data)
}

#[wasm_bindgen(js_name = cloudVaultKeyId)]
pub fn cloud_vault_key_id(key: &[u8]) -> Result<String, JsError> {
    cloudvault::vault_key_id(key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultKeyedHashHex)]
pub fn cloud_vault_keyed_hash_hex(
    data: &[u8],
    key: &[u8],
    purpose: CloudVaultHashPurpose,
) -> Result<String, JsError> {
    cloudvault::keyed_hash_hex(data, key, purpose.into()).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultExpectedSessionBodyHash)]
pub fn cloud_vault_expected_session_body_hash(
    data: &[u8],
    key: &[u8],
    body_hash_version: u32,
) -> Result<String, JsError> {
    cloudvault::expected_session_body_hash(data, key, body_hash_version).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultAesGcmSealCombined)]
pub fn cloud_vault_aes_gcm_seal_combined(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, JsError> {
    cloudvault::aes_gcm_seal_combined(plaintext, key, nonce, aad).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultAesGcmOpenCombined)]
pub fn cloud_vault_aes_gcm_open_combined(
    combined: &[u8],
    key: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, JsError> {
    cloudvault::aes_gcm_open_combined(combined, key, aad).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultBase64Encode)]
pub fn cloud_vault_base64_encode(data: &[u8]) -> String {
    cloudvault::base64_encode(data)
}

#[wasm_bindgen(js_name = cloudVaultBase64DecodeStrict)]
pub fn cloud_vault_base64_decode_strict(value: &str) -> Result<Vec<u8>, JsError> {
    cloudvault::base64_decode_strict(value).map_err(js_error)
}

fn context(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<CloudVaultAadContext, JsError> {
    CloudVaultAadContext::new(
        uid,
        collection,
        doc_id,
        field,
        schema_version,
        purpose.as_deref(),
    )
    .map_err(js_error)
}

fn js_error(error: CloudVaultError) -> JsError {
    let code = match error {
        CloudVaultError::InvalidKeyLength => "invalid_key_length",
        CloudVaultError::InvalidAadPart => "invalid_aad_part",
        CloudVaultError::InvalidSchemaVersion => "invalid_schema_version",
        CloudVaultError::AadMismatch => "aad_mismatch",
        CloudVaultError::LegacyAadRejected => "legacy_aad_rejected",
        CloudVaultError::UnsupportedHashVersion => "unsupported_hash_version",
        CloudVaultError::DerivationFailure => "derivation_failure",
        CloudVaultError::InvalidNonceLength => "invalid_nonce_length",
        CloudVaultError::InvalidCombinedLength => "invalid_combined_length",
        CloudVaultError::AuthenticationFailed => "authentication_failed",
        CloudVaultError::InvalidUtf8 => "invalid_utf8",
        CloudVaultError::InvalidBase64 => "invalid_base64",
    };
    JsError::new(&format!("{code}: {error}"))
}
