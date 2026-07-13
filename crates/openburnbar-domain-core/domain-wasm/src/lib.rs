use openburnbar_domain_core::cloudvault::{
    self, CloudVaultAadContext, CloudVaultError, CloudVaultHashPurpose as CoreHashPurpose,
};
use openburnbar_domain_core::cloudvault_rewrap::{
    self, CloudVaultDocumentRewrapError, CloudVaultDocumentRewrapRequest,
};
use wasm_bindgen::prelude::*;
use zeroize::{Zeroize, Zeroizing};

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

#[wasm_bindgen]
pub struct CloudVaultRecoveryWrappedVaultKey {
    combined: Vec<u8>,
    verification_hash: String,
}

#[wasm_bindgen]
impl CloudVaultRecoveryWrappedVaultKey {
    #[wasm_bindgen(getter)]
    pub fn combined(&self) -> Vec<u8> {
        self.combined.clone()
    }

    #[wasm_bindgen(getter, js_name = verificationHash)]
    pub fn verification_hash(&self) -> String {
        self.verification_hash.clone()
    }
}

#[wasm_bindgen]
pub struct CloudVaultEscrowWireParts {
    ephemeral_public_key: Vec<u8>,
    aes_gcm_combined: Vec<u8>,
}

#[wasm_bindgen]
impl CloudVaultEscrowWireParts {
    #[wasm_bindgen(getter, js_name = ephemeralPublicKey)]
    pub fn ephemeral_public_key(&self) -> Vec<u8> {
        self.ephemeral_public_key.clone()
    }

    #[wasm_bindgen(getter, js_name = aesGcmCombined)]
    pub fn aes_gcm_combined(&self) -> Vec<u8> {
        self.aes_gcm_combined.clone()
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

#[wasm_bindgen(js_name = cloudVaultNormalizeRecoveryKey)]
pub fn cloud_vault_normalize_recovery_key(recovery_key: &str) -> Result<String, JsError> {
    cloudvault::normalize_recovery_key(recovery_key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultRecoveryWrappingKey)]
pub fn cloud_vault_recovery_wrapping_key(recovery_key: &str) -> Result<Vec<u8>, JsError> {
    cloudvault::recovery_wrapping_key(recovery_key)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultRecoveryVerificationHash)]
pub fn cloud_vault_recovery_verification_hash(recovery_key: &str) -> Result<String, JsError> {
    cloudvault::recovery_verification_hash(recovery_key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultRecoveryWrapVaultKey)]
pub fn cloud_vault_recovery_wrap_vault_key(
    vault_key: &[u8],
    recovery_key: &str,
    nonce: &[u8],
) -> Result<CloudVaultRecoveryWrappedVaultKey, JsError> {
    cloudvault::recovery_wrap_vault_key(vault_key, recovery_key, nonce)
        .map(|wrapped| CloudVaultRecoveryWrappedVaultKey {
            combined: wrapped.combined,
            verification_hash: wrapped.verification_hash,
        })
        .map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultRecoveryOpenVaultKey)]
pub fn cloud_vault_recovery_open_vault_key(
    combined: &[u8],
    recovery_key: &str,
) -> Result<Vec<u8>, JsError> {
    cloudvault::recovery_open_vault_key(combined, recovery_key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultValidateP256X963PublicKey)]
pub fn cloud_vault_validate_p256_x963_public_key(public_key: &[u8]) -> Result<(), JsError> {
    cloudvault::validate_p256_x963_public_key(public_key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowWrappingKey)]
pub fn cloud_vault_escrow_wrapping_key(shared_secret: &[u8]) -> Result<Vec<u8>, JsError> {
    cloudvault::escrow_wrapping_key(shared_secret)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowAssembleWire)]
pub fn cloud_vault_escrow_assemble_wire(
    ephemeral_public_key: &[u8],
    aes_gcm_combined: &[u8],
) -> Result<Vec<u8>, JsError> {
    cloudvault::escrow_assemble_wire(ephemeral_public_key, aes_gcm_combined).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowSplitWire)]
pub fn cloud_vault_escrow_split_wire(wire: &[u8]) -> Result<CloudVaultEscrowWireParts, JsError> {
    cloudvault::escrow_split_wire(wire)
        .map(|parts| CloudVaultEscrowWireParts {
            ephemeral_public_key: parts.ephemeral_public_key,
            aes_gcm_combined: parts.aes_gcm_combined,
        })
        .map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowSeal)]
pub fn cloud_vault_escrow_seal(
    plaintext: &[u8],
    ephemeral_public_key: &[u8],
    shared_secret: &[u8],
    nonce: &[u8],
) -> Result<Vec<u8>, JsError> {
    cloudvault::escrow_seal(plaintext, ephemeral_public_key, shared_secret, nonce).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowOpen)]
pub fn cloud_vault_escrow_open(wire: &[u8], shared_secret: &[u8]) -> Result<Vec<u8>, JsError> {
    cloudvault::escrow_open(wire, shared_secret).map_err(js_error)
}

/// Whole-document rewrap for browser/Tauri consumers. `request_json` is the
/// strict camelCase serialization of `CloudVaultDocumentRewrapRequest`; unknown
/// fields and malformed envelope variants are rejected by serde.
#[wasm_bindgen(js_name = cloudVaultRewrapDocumentJson)]
pub fn cloud_vault_rewrap_document_json(
    request_json: &str,
    old_key: &[u8],
    new_key: &[u8],
    new_vault_key_id: &str,
) -> Result<String, JsError> {
    let request: CloudVaultDocumentRewrapRequest = serde_json::from_str(request_json)
        .map_err(|error| JsError::new(&format!("invalid_rewrap_request: {error}")))?;
    let old_key_copy = Zeroizing::new(old_key.to_vec());
    let new_key_copy = Zeroizing::new(new_key.to_vec());
    cloudvault_rewrap::rewrap_document(&request, &old_key_copy, &new_key_copy, new_vault_key_id)
        .map_err(js_rewrap_error)
        .and_then(|value| {
            serde_json::to_string(&value)
                .map_err(|error| JsError::new(&format!("rewrap_result_encoding_failed: {error}")))
        })
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
        CloudVaultError::InvalidRecoveryKey => "invalid_recovery_key",
        CloudVaultError::InvalidSharedSecretLength => "invalid_shared_secret_length",
        CloudVaultError::InvalidP256PublicKey => "invalid_p256_public_key",
        CloudVaultError::InvalidEscrowWireLength => "invalid_escrow_wire_length",
    };
    JsError::new(&format!("{code}: {error}"))
}

fn js_rewrap_error(error: CloudVaultDocumentRewrapError) -> JsError {
    let code = match &error {
        CloudVaultDocumentRewrapError::Crypto(inner) => {
            return js_error(*inner);
        }
        CloudVaultDocumentRewrapError::NewVaultKeyIdMismatch => "new_vault_key_id_mismatch",
        CloudVaultDocumentRewrapError::BoundsExceeded => "rewrap_bounds_exceeded",
        CloudVaultDocumentRewrapError::InvalidFieldSet => "invalid_rewrap_field_set",
        CloudVaultDocumentRewrapError::InvalidEnvelope => "invalid_rewrap_envelope",
        CloudVaultDocumentRewrapError::InvalidNoncePlan => "invalid_rewrap_nonce_plan",
        CloudVaultDocumentRewrapError::InvalidText => "invalid_rewrap_text",
        CloudVaultDocumentRewrapError::IntegrityMismatch => "rewrap_integrity_mismatch",
    };
    JsError::new(&format!("{code}: {error}"))
}
