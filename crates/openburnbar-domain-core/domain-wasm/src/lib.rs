use num_traits::ToPrimitive;
use openburnbar_domain_core::cloudvault::{
    self, CloudVaultAadContext, CloudVaultError, CloudVaultHashPurpose as CoreHashPurpose,
};
use openburnbar_domain_core::cloudvault_rewrap::{
    self, CloudVaultDocumentRewrapError, CloudVaultDocumentRewrapRequest,
};
use openburnbar_domain_core::cloudvault_search::{
    self, CloudVaultSearchError, CloudVaultSearchOperation as CoreSearchOperation,
};
use openburnbar_domain_core::pensieve_vectors;
use openburnbar_domain_core::pricing::{self, TokenBuckets, TokenRates};
use wasm_bindgen::prelude::*;
use zeroize::{Zeroize, Zeroizing};

#[wasm_bindgen(js_name = domainCoreAbiVersion)]
pub fn domain_core_abi_version() -> u32 {
    openburnbar_domain_core::DOMAIN_CORE_ABI_VERSION
}

#[wasm_bindgen(js_name = domainCoreVersion)]
pub fn domain_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[wasm_bindgen(js_name = domainCoreSourceFingerprint)]
pub fn domain_core_source_fingerprint() -> String {
    env!("OPENBURNBAR_DOMAIN_CORE_SOURCE_FINGERPRINT").to_owned()
}

#[wasm_bindgen(js_name = calculateTokenCostNanoUsd)]
pub fn calculate_token_cost_nano_usd(
    rates: &[u64],
    buckets: &[u64],
    has_cache_creation_rate: bool,
) -> Result<u64, JsError> {
    if rates.len() != 4 || buckets.len() != 4 {
        return Err(JsError::new(
            "invalid_pricing_vector: expected four rates and four token buckets",
        ));
    }
    pricing::token_cost_nano_usd(
        TokenRates {
            input_nano_usd_per_m_token: rates[0],
            output_nano_usd_per_m_token: rates[1],
            cache_creation_nano_usd_per_m_token: has_cache_creation_rate.then_some(rates[2]),
            cache_read_nano_usd_per_m_token: rates[3],
        },
        TokenBuckets {
            input_tokens: buckets[0],
            output_tokens: buckets[1],
            cache_creation_tokens: buckets[2],
            cache_read_tokens: buckets[3],
        },
    )
    .map_err(|error| JsError::new(&error.to_string()))
}

#[wasm_bindgen(js_name = isLegacyKimiWireEvent)]
pub fn is_legacy_kimi_wire_event(provider: &str, model: &str) -> bool {
    pricing::is_legacy_kimi_wire_event(provider, model)
}

/// Returns `[total_tokens, cost_nano_usd]`; the canonical model is exported separately.
#[wasm_bindgen(js_name = priceLegacyKimiWireEvent)]
pub fn price_legacy_kimi_wire_event(
    input_tokens: u64,
    output_tokens: u64,
    cache_creation_tokens: u64,
    cache_read_tokens: u64,
) -> Result<Vec<u64>, JsError> {
    let result = pricing::legacy_kimi_metrics(TokenBuckets {
        input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
    })
    .map_err(|error| JsError::new(&error.to_string()))?;
    Ok(vec![result.total_tokens, result.cost_nano_usd])
}

#[wasm_bindgen(js_name = legacyKimiWireModel)]
pub fn legacy_kimi_wire_model() -> String {
    pricing::legacy_kimi_model().to_owned()
}

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

#[wasm_bindgen]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudVaultSearchOperation {
    Token,
    Index,
    Query,
    Semantic,
}

impl From<CloudVaultSearchOperation> for CoreSearchOperation {
    fn from(value: CloudVaultSearchOperation) -> Self {
        match value {
            CloudVaultSearchOperation::Token => Self::Token,
            CloudVaultSearchOperation::Index => Self::Index,
            CloudVaultSearchOperation::Query => Self::Query,
            CloudVaultSearchOperation::Semantic => Self::Semantic,
        }
    }
}

#[wasm_bindgen]
pub struct CloudVaultSearchAnalysis {
    normalized_tokens: Vec<String>,
    exact_phrase_tokens: Vec<String>,
    semantic_features: Vec<String>,
}

impl Drop for CloudVaultSearchAnalysis {
    fn drop(&mut self) {
        self.normalized_tokens.zeroize();
        self.exact_phrase_tokens.zeroize();
        self.semantic_features.zeroize();
    }
}

#[wasm_bindgen]
impl CloudVaultSearchAnalysis {
    #[wasm_bindgen(getter, js_name = normalizedTokenCount)]
    pub fn normalized_token_count(&self) -> usize {
        self.normalized_tokens.len()
    }

    #[wasm_bindgen(js_name = normalizedTokenAt)]
    pub fn normalized_token_at(&self, index: usize) -> Option<String> {
        self.normalized_tokens.get(index).cloned()
    }

    #[wasm_bindgen(getter, js_name = exactPhraseTokenCount)]
    pub fn exact_phrase_token_count(&self) -> usize {
        self.exact_phrase_tokens.len()
    }

    #[wasm_bindgen(js_name = exactPhraseTokenAt)]
    pub fn exact_phrase_token_at(&self, index: usize) -> Option<String> {
        self.exact_phrase_tokens.get(index).cloned()
    }

    #[wasm_bindgen(getter, js_name = semanticFeatureCount)]
    pub fn semantic_feature_count(&self) -> usize {
        self.semantic_features.len()
    }

    #[wasm_bindgen(js_name = semanticFeatureAt)]
    pub fn semantic_feature_at(&self, index: usize) -> Option<String> {
        self.semantic_features.get(index).cloned()
    }
}

#[wasm_bindgen]
pub struct CloudVaultSearchResult {
    operation: CloudVaultSearchOperation,
    hashes: Vec<String>,
}

#[wasm_bindgen]
impl CloudVaultSearchResult {
    #[wasm_bindgen(getter)]
    pub fn operation(&self) -> CloudVaultSearchOperation {
        self.operation
    }

    #[wasm_bindgen(getter, js_name = hashCount)]
    pub fn hash_count(&self) -> usize {
        self.hashes.len()
    }

    #[wasm_bindgen(js_name = hashAt)]
    pub fn hash_at(&self, index: usize) -> Option<String> {
        self.hashes.get(index).cloned()
    }
}

#[wasm_bindgen(js_name = cloudVaultAadV2)]
pub fn cloud_vault_aad_v2(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: f64,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(
        uid,
        collection,
        doc_id,
        field,
        checked_schema_version(schema_version)?,
        purpose,
    )?
    .v2_string())
}

#[wasm_bindgen(js_name = cloudVaultAadV1)]
pub fn cloud_vault_aad_v1(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: f64,
    purpose: Option<String>,
) -> Result<String, JsError> {
    Ok(context(
        uid,
        collection,
        doc_id,
        field,
        checked_schema_version(schema_version)?,
        purpose,
    )?
    .v1_string())
}

#[wasm_bindgen(js_name = cloudVaultSha256Hex)]
pub fn cloud_vault_sha256_hex(data: &[u8]) -> Result<String, JsError> {
    cloudvault::sha256_hex(data).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultKeyId)]
pub fn cloud_vault_key_id(mut key: Vec<u8>) -> Result<String, JsError> {
    let result = cloudvault::vault_key_id(&key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultKeyedHashHex)]
pub fn cloud_vault_keyed_hash_hex(
    mut data: Vec<u8>,
    mut key: Vec<u8>,
    purpose: CloudVaultHashPurpose,
) -> Result<String, JsError> {
    let result = cloudvault::keyed_hash_hex(&data, &key, purpose.into()).map_err(js_error);
    data.zeroize();
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = pensieveVectorCloak)]
pub fn pensieve_vector_cloak(
    mut vector: Vec<f64>,
    mut vault_key: Vec<u8>,
    model_version: String,
) -> Result<Vec<f64>, JsError> {
    let result = pensieve_vectors::cloak(&vector, &vault_key, &model_version)
        .map_err(|error| JsError::new(&error.to_string()));
    vector.zeroize();
    vault_key.zeroize();
    result
}

#[wasm_bindgen(js_name = pensieveL2Normalize)]
pub fn pensieve_l2_normalize(mut vector: Vec<f64>) -> Result<Vec<f64>, JsError> {
    let result =
        pensieve_vectors::l2_normalize(&vector).map_err(|error| JsError::new(&error.to_string()));
    vector.zeroize();
    result
}

#[wasm_bindgen(js_name = pensieveDeterministicEmbed)]
pub fn pensieve_deterministic_embed(
    mut text: String,
    dimensions: u32,
    is_query: bool,
) -> Result<Vec<f64>, JsError> {
    let result = pensieve_vectors::deterministic_embed(&text, dimensions as usize, is_query)
        .map_err(|error| JsError::new(&error.to_string()));
    text.zeroize();
    result
}

#[wasm_bindgen(js_name = pensieveDeterministicEmbedAndCloak)]
pub fn pensieve_deterministic_embed_and_cloak(
    mut text: String,
    dimensions: u32,
    is_query: bool,
    mut vault_key: Vec<u8>,
    model_version: String,
) -> Result<Vec<f64>, JsError> {
    let result = pensieve_vectors::deterministic_embed_and_cloak(
        &text,
        dimensions as usize,
        is_query,
        &vault_key,
        &model_version,
    )
    .map_err(|error| JsError::new(&error.to_string()));
    text.zeroize();
    vault_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultExpectedSessionBodyHash)]
pub fn cloud_vault_expected_session_body_hash(
    mut data: Vec<u8>,
    mut key: Vec<u8>,
    body_hash_version: u32,
) -> Result<String, JsError> {
    let result =
        cloudvault::expected_session_body_hash(&data, &key, body_hash_version).map_err(js_error);
    data.zeroize();
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultProjectMemoryDocId)]
pub fn cloud_vault_project_memory_doc_id(slug: &str, mut key: Vec<u8>) -> Result<String, JsError> {
    let result = cloudvault::project_memory_doc_id(slug, &key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultPensieveDedupHash)]
pub fn cloud_vault_pensieve_dedup_hash(
    plaintext: &str,
    mut key: Vec<u8>,
) -> Result<String, JsError> {
    let result = cloudvault::pensieve_dedup_hash(plaintext, &key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultPensieveSlugHmac)]
pub fn cloud_vault_pensieve_slug_hmac(slug: &str, mut key: Vec<u8>) -> Result<String, JsError> {
    let result = cloudvault::pensieve_slug_hmac(slug, &key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultPensieveProvenanceHash)]
pub fn cloud_vault_pensieve_provenance_hash(
    value: &str,
    mut key: Vec<u8>,
) -> Result<String, JsError> {
    let result = cloudvault::pensieve_provenance_hash(value, &key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultSubscriptionDocId)]
pub fn cloud_vault_subscription_doc_id(
    agent_uri: &str,
    topic_id: &str,
    mut key: Vec<u8>,
) -> Result<String, JsError> {
    let result = cloudvault::subscription_doc_id(agent_uri, topic_id, &key).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultAesGcmSealCombined)]
pub fn cloud_vault_aes_gcm_seal_combined(
    mut plaintext: Vec<u8>,
    mut key: Vec<u8>,
    nonce: &[u8],
    aad: &[u8],
) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::aes_gcm_seal_combined(&plaintext, &key, nonce, aad).map_err(js_error);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultAesGcmOpenCombined)]
pub fn cloud_vault_aes_gcm_open_combined(
    combined: &[u8],
    mut key: Vec<u8>,
    aad: &[u8],
) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::aes_gcm_open_combined(combined, &key, aad).map_err(js_error);
    key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultBase64Encode)]
pub fn cloud_vault_base64_encode(data: &[u8]) -> Result<String, JsError> {
    cloudvault::base64_encode_checked(data).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultBase64DecodeStrict)]
pub fn cloud_vault_base64_decode_strict(value: &str) -> Result<Vec<u8>, JsError> {
    cloudvault::base64_decode_strict(value).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultNormalizeRecoveryKey)]
pub fn cloud_vault_normalize_recovery_key(mut recovery_key: String) -> Result<String, JsError> {
    let result = cloudvault::normalize_recovery_key(&recovery_key).map_err(js_error);
    recovery_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultRecoveryWrappingKey)]
pub fn cloud_vault_recovery_wrapping_key(mut recovery_key: String) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::recovery_wrapping_key(&recovery_key)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(js_error);
    recovery_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultRecoveryVerificationHash)]
pub fn cloud_vault_recovery_verification_hash(mut recovery_key: String) -> Result<String, JsError> {
    let result = cloudvault::recovery_verification_hash(&recovery_key).map_err(js_error);
    recovery_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultRecoveryWrapVaultKey)]
pub fn cloud_vault_recovery_wrap_vault_key(
    mut vault_key: Vec<u8>,
    mut recovery_key: String,
    nonce: &[u8],
) -> Result<CloudVaultRecoveryWrappedVaultKey, JsError> {
    let result = cloudvault::recovery_wrap_vault_key(&vault_key, &recovery_key, nonce)
        .map(|wrapped| CloudVaultRecoveryWrappedVaultKey {
            combined: wrapped.combined,
            verification_hash: wrapped.verification_hash,
        })
        .map_err(js_error);
    vault_key.zeroize();
    recovery_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultRecoveryOpenVaultKey)]
pub fn cloud_vault_recovery_open_vault_key(
    combined: &[u8],
    mut recovery_key: String,
) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::recovery_open_vault_key(combined, &recovery_key).map_err(js_error);
    recovery_key.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultValidateP256X963PublicKey)]
pub fn cloud_vault_validate_p256_x963_public_key(public_key: &[u8]) -> Result<(), JsError> {
    cloudvault::validate_p256_x963_public_key(public_key).map_err(js_error)
}

#[wasm_bindgen(js_name = cloudVaultEscrowWrappingKey)]
pub fn cloud_vault_escrow_wrapping_key(mut shared_secret: Vec<u8>) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::escrow_wrapping_key(&shared_secret)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(js_error);
    shared_secret.zeroize();
    result
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
    mut plaintext: Vec<u8>,
    ephemeral_public_key: &[u8],
    mut shared_secret: Vec<u8>,
    nonce: &[u8],
) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::escrow_seal(&plaintext, ephemeral_public_key, &shared_secret, nonce)
        .map_err(js_error);
    plaintext.zeroize();
    shared_secret.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultEscrowOpen)]
pub fn cloud_vault_escrow_open(
    wire: &[u8],
    mut shared_secret: Vec<u8>,
) -> Result<Vec<u8>, JsError> {
    let result = cloudvault::escrow_open(wire, &shared_secret).map_err(js_error);
    shared_secret.zeroize();
    result
}

/// Whole-document rewrap for browser/Tauri consumers. `request_json` is the
/// strict camelCase serialization of `CloudVaultDocumentRewrapRequest`; unknown
/// fields and malformed envelope variants are rejected by serde.
#[wasm_bindgen(js_name = cloudVaultRewrapDocumentJson)]
pub fn cloud_vault_rewrap_document_json(
    request_json: &str,
    old_key: Vec<u8>,
    new_key: Vec<u8>,
    new_vault_key_id: &str,
) -> Result<String, JsError> {
    if request_json.len() > cloudvault_rewrap::MAX_REWRAP_JSON_BYTES {
        return Err(JsError::new(
            "rewrap_bounds_exceeded: request JSON is too large",
        ));
    }
    let request: CloudVaultDocumentRewrapRequest = serde_json::from_str(request_json)
        .map_err(|error| JsError::new(&format!("invalid_rewrap_request: {error}")))?;
    let old_key = Zeroizing::new(old_key);
    let new_key = Zeroizing::new(new_key);
    cloudvault_rewrap::rewrap_document(&request, &old_key, &new_key, new_vault_key_id)
        .map_err(js_rewrap_error)
        .and_then(|value| {
            serde_json::to_string(&value)
                .map_err(|error| JsError::new(&format!("rewrap_result_encoding_failed: {error}")))
        })
}

#[wasm_bindgen(js_name = cloudVaultSearchAnalyze)]
pub fn cloud_vault_search_analyze(mut text: String) -> Result<CloudVaultSearchAnalysis, JsError> {
    let result = cloudvault_search::analyze(&text)
        .map(|analysis| CloudVaultSearchAnalysis {
            normalized_tokens: analysis.normalized_tokens,
            exact_phrase_tokens: analysis.exact_phrase_tokens,
            semantic_features: analysis.semantic_features,
        })
        .map_err(search_js_error);
    text.zeroize();
    result
}

#[wasm_bindgen(js_name = cloudVaultSearch)]
pub fn cloud_vault_search(
    operation: CloudVaultSearchOperation,
    mut text: String,
    mut vault_key: Vec<u8>,
    limit: i32,
) -> Result<CloudVaultSearchResult, JsError> {
    let result = cloudvault_search::search(operation.into(), &text, &vault_key, limit)
        .map(|result| CloudVaultSearchResult {
            operation,
            hashes: result.hashes,
        })
        .map_err(search_js_error);
    text.zeroize();
    vault_key.zeroize();
    result
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

fn checked_schema_version(value: f64) -> Result<u32, JsError> {
    if !value.is_finite() || value.fract() != 0.0 || value < 2.0 || value > f64::from(u32::MAX) {
        return Err(JsError::new(
            "invalid_schema_version: expected an integer from 2 through 4294967295",
        ));
    }
    value.to_u32().ok_or_else(|| {
        JsError::new("invalid_schema_version: expected an integer from 2 through 4294967295")
    })
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
        CloudVaultError::InputTooLarge => "input_too_large",
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
        CloudVaultDocumentRewrapError::InvalidKeyRotation => "invalid_rewrap_key_rotation",
    };
    JsError::new(&format!("{code}: {error}"))
}

fn search_js_error(error: CloudVaultSearchError) -> JsError {
    let code = match error {
        CloudVaultSearchError::InvalidKeyLength => "invalid_key_length",
        CloudVaultSearchError::TextTooLarge => "search_text_too_large",
        CloudVaultSearchError::LimitTooLarge => "search_limit_too_large",
        CloudVaultSearchError::TooManyTokens => "search_too_many_tokens",
        CloudVaultSearchError::DerivationFailure => "derivation_failure",
    };
    JsError::new(&format!("{code}: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wasm_surface_uses_shared_domain_core_abi_authority() {
        assert_eq!(
            super::domain_core_abi_version(),
            openburnbar_domain_core::DOMAIN_CORE_ABI_VERSION
        );
    }

    #[test]
    fn wasm_pensieve_l2_normalize_preserves_the_public_contract() -> Result<(), JsError> {
        assert_eq!(pensieve_l2_normalize(vec![3.0, 4.0])?, vec![0.6, 0.8]);
        assert_eq!(pensieve_l2_normalize(Vec::new())?, Vec::<f64>::new());
        Ok(())
    }

    #[test]
    fn wasm_opaque_identifier_surface_matches_cross_language_vectors() -> Result<(), JsError> {
        let key: Vec<u8> = (0_u8..32).collect();
        assert_eq!(
            cloud_vault_project_memory_doc_id("la-hormiga-dormida", key.clone())?,
            "pm_445f38c87b0e3c474c2be6339b8cd8d8"
        );
        assert_eq!(
            cloud_vault_pensieve_dedup_hash("deploy the daemon before midnight", key.clone())?,
            "e55f699579cba539fb8f3a87c77bd768a95e331859c9fca9c89d21dac0c6d433"
        );
        assert_eq!(
            cloud_vault_pensieve_slug_hmac("burnbar-docs-secret-runbook", key.clone())?,
            "f77ecba2eaa6012fb4a6846d8fd218b61a04094cad346683f029e1636da7a96d"
        );
        assert_eq!(
            cloud_vault_pensieve_provenance_hash("source:burnbar", key.clone())?,
            "4f069319dcb12b868983bc04992c7871f3682c4b107a9e0bbfb8348fcbd8fc4e"
        );
        assert_eq!(
            cloud_vault_subscription_doc_id(
                "agent://burnbar/research-scout",
                "agent-updates",
                key,
            )?,
            "sub_4b6aff30300ab361ad751d8d7c6b2bb0"
        );
        Ok(())
    }
}
