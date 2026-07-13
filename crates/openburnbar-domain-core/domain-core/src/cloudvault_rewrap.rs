//! Whole-document CloudVault envelope rewrap.
//!
//! Platform adapters map dynamic document dictionaries into these typed inputs,
//! provide one nonce for every envelope that will be resealed, and apply the
//! returned field/metadata intents. This module owns no randomness, clock,
//! persistence, or platform key handles.

use crate::cloudvault::{
    aes_gcm_open_combined, aes_gcm_open_detached, aes_gcm_seal_combined, aes_gcm_seal_detached,
    base64_decode_strict, base64_encode, keyed_hash_hex, sha256_hex, vault_key_id,
    CloudVaultAadContext, CloudVaultError, CloudVaultHashPurpose, AES_GCM_NONCE_LENGTH,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use zeroize::Zeroizing;

const AES_GCM_ALGORITHM: &str = "AES-256-GCM";
const SEALED_PAYLOAD_AAD: &str = "OpenBurnBar-CloudVaultSealedPayload-v2";
const BLOB_AAD: &str = "OpenBurnBar-CloudVaultBlob-v2";
const CURRENT_SCHEMA_VERSION: u32 = 2;
const CURRENT_KEY_VERSION: u32 = 1;
const BLOB_INTEGRITY_HASH_VERSION: u32 = 1;

pub const MAX_DOCUMENT_FIELDS: usize = 256;
pub const MAX_FIELD_NAME_BYTES: usize = 256;
pub const MAX_DOCUMENT_CIPHERTEXT_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_REWRAP_JOB_ID_BYTES: usize = 256;
// The decoded cap expanded to canonical Base64 plus worst-case component padding.
const MAX_DOCUMENT_CIPHERTEXT_ENCODED_BYTES: usize = 22_372_694;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloudVaultDocumentRewrapRequest {
    pub uid: String,
    pub collection: String,
    pub doc_id: String,
    /// Every top-level field in the source document, including non-envelope fields.
    pub document_field_names: Vec<String>,
    pub envelopes: Vec<CloudVaultDocumentEnvelope>,
    /// Exactly one 12-byte nonce per envelope that is not skipped.
    pub reseal_nonces: Vec<Vec<u8>>,
    pub vault_generation: Option<i64>,
    pub rotation_job_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum CloudVaultDocumentEnvelope {
    SealedPayload {
        field_name: String,
        schema_version: u32,
        algorithm: String,
        key_version: u32,
        vault_key_id: String,
        sealed_box_base64: String,
        aad: Option<String>,
    },
    SealedText {
        field_name: String,
        schema_version: Option<u32>,
        algorithm: String,
        key_version: u32,
        nonce: String,
        ciphertext: String,
        tag: String,
        aad: Option<String>,
    },
    Blob {
        field_name: String,
        schema_version: u32,
        algorithm: String,
        key_version: u32,
        plaintext_sha256: Option<String>,
        plaintext_hmac: Option<String>,
        integrity_hash_version: Option<u32>,
        sealed_box_base64: String,
        aad: Option<String>,
        /// The platform map contains a `createdAt` member that Rust must not decode.
        has_created_at: bool,
    },
}

impl CloudVaultDocumentEnvelope {
    pub fn field_name(&self) -> &str {
        match self {
            Self::SealedPayload { field_name, .. }
            | Self::SealedText { field_name, .. }
            | Self::Blob { field_name, .. } => field_name,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloudVaultCompanionUpdateIntent {
    pub source_field_name: String,
    pub companion_field_name: String,
    pub vault_key_id: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloudVaultPreservedEnvelopeMemberIntent {
    pub source_field_name: String,
    pub member_name: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CloudVaultDocumentRewrapResult {
    pub changed_fields: Vec<String>,
    pub skipped_fields: Vec<String>,
    pub rewrapped_envelopes: Vec<CloudVaultDocumentEnvelope>,
    pub companion_update_intents: Vec<CloudVaultCompanionUpdateIntent>,
    pub preserved_member_intents: Vec<CloudVaultPreservedEnvelopeMemberIntent>,
    pub vault_generation_update: Option<i64>,
    pub rotation_job_id_update: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CloudVaultDocumentRewrapError {
    #[error(transparent)]
    Crypto(#[from] CloudVaultError),
    #[error("the new vault key id does not match the new key")]
    NewVaultKeyIdMismatch,
    #[error("the document exceeds the rewrap field, field-name, or ciphertext bound")]
    BoundsExceeded,
    #[error("document field names and envelope field names must be unique and consistent")]
    InvalidFieldSet,
    #[error("the envelope algorithm, schema, key version, or integrity metadata is invalid")]
    InvalidEnvelope,
    #[error("the caller must supply exactly one unique 12-byte nonce per resealed envelope")]
    InvalidNoncePlan,
    #[error("the sealed text plaintext is not valid UTF-8")]
    InvalidText,
    #[error("the source envelope integrity hash did not verify")]
    IntegrityMismatch,
}

pub fn rewrap_document(
    request: &CloudVaultDocumentRewrapRequest,
    old_key: &[u8],
    new_key: &[u8],
    new_vault_key_id: &str,
) -> Result<CloudVaultDocumentRewrapResult, CloudVaultDocumentRewrapError> {
    if vault_key_id(new_key)? != new_vault_key_id {
        return Err(CloudVaultDocumentRewrapError::NewVaultKeyIdMismatch);
    }
    validate_request(request)?;

    let mut envelopes: Vec<&CloudVaultDocumentEnvelope> = request.envelopes.iter().collect();
    envelopes.sort_by(|left, right| left.field_name().cmp(right.field_name()));

    let expected_nonce_count = envelopes
        .iter()
        .filter(|envelope| !should_skip(envelope, new_vault_key_id))
        .count();
    if request.reseal_nonces.len() != expected_nonce_count {
        return Err(CloudVaultDocumentRewrapError::InvalidNoncePlan);
    }
    let mut seen_nonces = BTreeSet::new();
    for nonce in &request.reseal_nonces {
        if nonce.len() != AES_GCM_NONCE_LENGTH || !seen_nonces.insert(nonce.as_slice()) {
            return Err(CloudVaultDocumentRewrapError::InvalidNoncePlan);
        }
    }

    let document_fields: BTreeSet<&str> = request
        .document_field_names
        .iter()
        .map(String::as_str)
        .collect();
    let mut nonce_index = 0;
    let mut changed_fields = Vec::with_capacity(expected_nonce_count);
    let mut skipped_fields = Vec::new();
    let mut rewrapped_envelopes = Vec::with_capacity(expected_nonce_count);
    let mut companion_update_intents = Vec::new();
    let mut preserved_member_intents = Vec::new();

    for envelope in envelopes {
        let field_name = envelope.field_name();
        let context = CloudVaultAadContext::new(
            &request.uid,
            &request.collection,
            &request.doc_id,
            field_name,
            CURRENT_SCHEMA_VERSION,
            None,
        )?;
        if should_skip(envelope, new_vault_key_id) {
            validate_skipped_payload(envelope, new_key, &context)?;
            skipped_fields.push(field_name.to_owned());
            continue;
        }
        let nonce = &request.reseal_nonces[nonce_index];
        nonce_index += 1;
        let rewrapped = rewrap_envelope(
            envelope,
            old_key,
            new_key,
            new_vault_key_id,
            nonce,
            &context,
        )?;
        changed_fields.push(field_name.to_owned());
        rewrapped_envelopes.push(rewrapped);

        if matches!(
            envelope,
            CloudVaultDocumentEnvelope::Blob {
                has_created_at: true,
                ..
            }
        ) {
            preserved_member_intents.push(CloudVaultPreservedEnvelopeMemberIntent {
                source_field_name: field_name.to_owned(),
                member_name: "createdAt".to_owned(),
            });
        }

        let companion = match field_name {
            "sealedPayload" | "sealedReplyPayload" if document_fields.contains("vaultKeyID") => {
                Some("vaultKeyID")
            }
            "sealedStatePayload" if document_fields.contains("sealedStateVaultKeyID") => {
                Some("sealedStateVaultKeyID")
            }
            _ => None,
        };
        if let Some(companion_field_name) = companion {
            companion_update_intents.push(CloudVaultCompanionUpdateIntent {
                source_field_name: field_name.to_owned(),
                companion_field_name: companion_field_name.to_owned(),
                vault_key_id: new_vault_key_id.to_owned(),
            });
        }
    }

    let changed = !changed_fields.is_empty();
    Ok(CloudVaultDocumentRewrapResult {
        changed_fields,
        skipped_fields,
        rewrapped_envelopes,
        companion_update_intents,
        preserved_member_intents,
        vault_generation_update: changed.then_some(request.vault_generation).flatten(),
        rotation_job_id_update: changed.then(|| request.rotation_job_id.clone()).flatten(),
    })
}

fn validate_request(
    request: &CloudVaultDocumentRewrapRequest,
) -> Result<(), CloudVaultDocumentRewrapError> {
    if request.document_field_names.len() > MAX_DOCUMENT_FIELDS
        || request.envelopes.len() > MAX_DOCUMENT_FIELDS
        || request
            .rotation_job_id
            .as_ref()
            .is_some_and(|value| value.len() > MAX_REWRAP_JOB_ID_BYTES)
    {
        return Err(CloudVaultDocumentRewrapError::BoundsExceeded);
    }

    // Construct once to validate the three document-level path components.
    CloudVaultAadContext::new(
        &request.uid,
        &request.collection,
        &request.doc_id,
        "validation",
        CURRENT_SCHEMA_VERSION,
        None,
    )?;

    let mut document_fields = BTreeSet::new();
    for field in &request.document_field_names {
        validate_field_name(field)?;
        if !document_fields.insert(field.as_str()) {
            return Err(CloudVaultDocumentRewrapError::InvalidFieldSet);
        }
    }

    let mut envelope_fields = BTreeSet::new();
    let mut ciphertext_bytes = 0_usize;
    let mut encoded_ciphertext_bytes = 0_usize;
    for envelope in &request.envelopes {
        let field = envelope.field_name();
        validate_field_name(field)?;
        if !document_fields.contains(field) || !envelope_fields.insert(field) {
            return Err(CloudVaultDocumentRewrapError::InvalidFieldSet);
        }
        encoded_ciphertext_bytes = encoded_ciphertext_bytes
            .checked_add(encoded_ciphertext_len(envelope))
            .ok_or(CloudVaultDocumentRewrapError::BoundsExceeded)?;
        if encoded_ciphertext_bytes > MAX_DOCUMENT_CIPHERTEXT_ENCODED_BYTES {
            return Err(CloudVaultDocumentRewrapError::BoundsExceeded);
        }
        ciphertext_bytes = ciphertext_bytes
            .checked_add(decoded_ciphertext_len(envelope)?)
            .ok_or(CloudVaultDocumentRewrapError::BoundsExceeded)?;
        if ciphertext_bytes > MAX_DOCUMENT_CIPHERTEXT_BYTES {
            return Err(CloudVaultDocumentRewrapError::BoundsExceeded);
        }
    }
    Ok(())
}

fn encoded_ciphertext_len(envelope: &CloudVaultDocumentEnvelope) -> usize {
    match envelope {
        CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64, ..
        }
        | CloudVaultDocumentEnvelope::Blob {
            sealed_box_base64, ..
        } => sealed_box_base64.len(),
        CloudVaultDocumentEnvelope::SealedText {
            nonce,
            ciphertext,
            tag,
            ..
        } => nonce
            .len()
            .saturating_add(ciphertext.len())
            .saturating_add(tag.len()),
    }
}

fn validate_field_name(field: &str) -> Result<(), CloudVaultDocumentRewrapError> {
    if field.len() > MAX_FIELD_NAME_BYTES {
        return Err(CloudVaultDocumentRewrapError::BoundsExceeded);
    }
    CloudVaultAadContext::new("u", "c", "d", field, CURRENT_SCHEMA_VERSION, None)?;
    Ok(())
}

fn decoded_ciphertext_len(
    envelope: &CloudVaultDocumentEnvelope,
) -> Result<usize, CloudVaultDocumentRewrapError> {
    let decoded = match envelope {
        CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64, ..
        }
        | CloudVaultDocumentEnvelope::Blob {
            sealed_box_base64, ..
        } => base64_decode_strict(sealed_box_base64)?.len(),
        CloudVaultDocumentEnvelope::SealedText {
            nonce,
            ciphertext,
            tag,
            ..
        } => {
            base64_decode_strict(nonce)?.len()
                + base64_decode_strict(ciphertext)?.len()
                + base64_decode_strict(tag)?.len()
        }
    };
    Ok(decoded)
}

fn should_skip(envelope: &CloudVaultDocumentEnvelope, new_vault_key_id: &str) -> bool {
    matches!(
        envelope,
        CloudVaultDocumentEnvelope::SealedPayload { vault_key_id, .. }
            if vault_key_id == new_vault_key_id
    )
}

fn validate_skipped_payload(
    envelope: &CloudVaultDocumentEnvelope,
    new_key: &[u8],
    context: &CloudVaultAadContext,
) -> Result<(), CloudVaultDocumentRewrapError> {
    let CloudVaultDocumentEnvelope::SealedPayload {
        schema_version,
        algorithm,
        key_version,
        vault_key_id: source_vault_key_id,
        sealed_box_base64,
        aad,
        ..
    } = envelope
    else {
        return Err(CloudVaultDocumentRewrapError::InvalidEnvelope);
    };
    validate_common(*schema_version, algorithm, *key_version)?;
    if vault_key_id(new_key)? != *source_vault_key_id {
        return Err(CloudVaultDocumentRewrapError::InvalidEnvelope);
    }
    let source_aad = payload_source_aad(
        *schema_version,
        algorithm,
        *key_version,
        source_vault_key_id,
        aad.as_deref(),
        context,
    )?;
    let combined = base64_decode_strict(sealed_box_base64)?;
    let _plaintext = Zeroizing::new(aes_gcm_open_combined(&combined, new_key, &source_aad)?);
    Ok(())
}

fn rewrap_envelope(
    envelope: &CloudVaultDocumentEnvelope,
    old_key: &[u8],
    new_key: &[u8],
    new_vault_key_id: &str,
    nonce: &[u8],
    context: &CloudVaultAadContext,
) -> Result<CloudVaultDocumentEnvelope, CloudVaultDocumentRewrapError> {
    match envelope {
        CloudVaultDocumentEnvelope::SealedPayload {
            field_name,
            schema_version,
            algorithm,
            key_version,
            vault_key_id: source_vault_key_id,
            sealed_box_base64,
            aad,
        } => {
            validate_common(*schema_version, algorithm, *key_version)?;
            if vault_key_id(old_key)? != *source_vault_key_id {
                return Err(CloudVaultDocumentRewrapError::InvalidEnvelope);
            }
            let combined = base64_decode_strict(sealed_box_base64)?;
            let source_aad = payload_source_aad(
                *schema_version,
                algorithm,
                *key_version,
                source_vault_key_id,
                aad.as_deref(),
                context,
            )?;
            let plaintext = Zeroizing::new(aes_gcm_open_combined(&combined, old_key, &source_aad)?);
            let output_aad = context.v2_string();
            let sealed = aes_gcm_seal_combined(&plaintext, new_key, nonce, output_aad.as_bytes());
            Ok(CloudVaultDocumentEnvelope::SealedPayload {
                field_name: field_name.clone(),
                schema_version: CURRENT_SCHEMA_VERSION,
                algorithm: AES_GCM_ALGORITHM.to_owned(),
                key_version: CURRENT_KEY_VERSION,
                vault_key_id: new_vault_key_id.to_owned(),
                sealed_box_base64: base64_encode(&sealed?),
                aad: Some(output_aad),
            })
        }
        CloudVaultDocumentEnvelope::SealedText {
            field_name,
            schema_version,
            algorithm,
            key_version,
            nonce: source_nonce,
            ciphertext,
            tag,
            aad,
        } => {
            let schema = schema_version.unwrap_or(1);
            validate_common(schema, algorithm, *key_version)?;
            let source_aad = generic_source_aad(schema, aad.as_deref(), context)?;
            let source_nonce = base64_decode_strict(source_nonce)?;
            let source_ciphertext = base64_decode_strict(ciphertext)?;
            let source_tag = base64_decode_strict(tag)?;
            let plaintext = Zeroizing::new(aes_gcm_open_detached(
                &source_nonce,
                &source_ciphertext,
                &source_tag,
                old_key,
                &source_aad,
            )?);
            if std::str::from_utf8(&plaintext).is_err() {
                return Err(CloudVaultDocumentRewrapError::InvalidText);
            }
            let output_aad = context.v2_string();
            let sealed = aes_gcm_seal_detached(&plaintext, new_key, nonce, output_aad.as_bytes());
            let sealed = sealed?;
            Ok(CloudVaultDocumentEnvelope::SealedText {
                field_name: field_name.clone(),
                schema_version: Some(CURRENT_SCHEMA_VERSION),
                algorithm: AES_GCM_ALGORITHM.to_owned(),
                key_version: CURRENT_KEY_VERSION,
                nonce: base64_encode(&sealed.nonce),
                ciphertext: base64_encode(&sealed.ciphertext),
                tag: base64_encode(&sealed.tag),
                aad: Some(output_aad),
            })
        }
        CloudVaultDocumentEnvelope::Blob {
            field_name,
            schema_version,
            algorithm,
            key_version,
            plaintext_sha256,
            plaintext_hmac,
            integrity_hash_version,
            sealed_box_base64,
            aad,
            has_created_at,
        } => {
            validate_common(*schema_version, algorithm, *key_version)?;
            let source_aad = blob_source_aad(*schema_version, aad.as_deref(), context)?;
            let combined = base64_decode_strict(sealed_box_base64)?;
            let plaintext = Zeroizing::new(aes_gcm_open_combined(&combined, old_key, &source_aad)?);
            let integrity_matches = match *schema_version {
                1 => plaintext_sha256
                    .as_ref()
                    .is_some_and(|expected| sha256_hex(&plaintext) == *expected),
                CURRENT_SCHEMA_VERSION => {
                    *integrity_hash_version == Some(BLOB_INTEGRITY_HASH_VERSION)
                        && plaintext_hmac.as_ref().is_some_and(|expected| {
                            keyed_hash_hex(
                                &plaintext,
                                old_key,
                                CloudVaultHashPurpose::BlobIntegrity,
                            )
                            .is_ok_and(|actual| actual == *expected)
                        })
                }
                _ => false,
            };
            if !integrity_matches {
                return Err(CloudVaultDocumentRewrapError::IntegrityMismatch);
            }
            let output_aad = context.v2_string();
            let output_hmac =
                keyed_hash_hex(&plaintext, new_key, CloudVaultHashPurpose::BlobIntegrity)?;
            let sealed = aes_gcm_seal_combined(&plaintext, new_key, nonce, output_aad.as_bytes());
            Ok(CloudVaultDocumentEnvelope::Blob {
                field_name: field_name.clone(),
                schema_version: CURRENT_SCHEMA_VERSION,
                algorithm: AES_GCM_ALGORITHM.to_owned(),
                key_version: CURRENT_KEY_VERSION,
                plaintext_sha256: None,
                plaintext_hmac: Some(output_hmac),
                integrity_hash_version: Some(BLOB_INTEGRITY_HASH_VERSION),
                sealed_box_base64: base64_encode(&sealed?),
                aad: Some(output_aad),
                has_created_at: *has_created_at,
            })
        }
    }
}

fn validate_common(
    schema_version: u32,
    algorithm: &str,
    key_version: u32,
) -> Result<(), CloudVaultDocumentRewrapError> {
    if !matches!(schema_version, 1 | CURRENT_SCHEMA_VERSION)
        || algorithm != AES_GCM_ALGORITHM
        || key_version != CURRENT_KEY_VERSION
    {
        Err(CloudVaultDocumentRewrapError::InvalidEnvelope)
    } else {
        Ok(())
    }
}

fn generic_source_aad(
    schema_version: u32,
    aad: Option<&str>,
    context: &CloudVaultAadContext,
) -> Result<Vec<u8>, CloudVaultDocumentRewrapError> {
    match schema_version {
        1 => Ok(Vec::new()),
        CURRENT_SCHEMA_VERSION => {
            let aad = aad.ok_or(CloudVaultDocumentRewrapError::InvalidEnvelope)?;
            // Rewrap is the post-cutover path: accept only exact v2 path binding.
            context.resolve(aad, true).map_err(Into::into)
        }
        _ => Err(CloudVaultDocumentRewrapError::InvalidEnvelope),
    }
}

fn blob_source_aad(
    schema_version: u32,
    aad: Option<&str>,
    context: &CloudVaultAadContext,
) -> Result<Vec<u8>, CloudVaultDocumentRewrapError> {
    if schema_version == CURRENT_SCHEMA_VERSION && aad == Some(BLOB_AAD) {
        Ok(Vec::new())
    } else {
        generic_source_aad(schema_version, aad, context)
    }
}

fn payload_source_aad(
    schema_version: u32,
    algorithm: &str,
    key_version: u32,
    vault_key_id: &str,
    aad: Option<&str>,
    context: &CloudVaultAadContext,
) -> Result<Vec<u8>, CloudVaultDocumentRewrapError> {
    if schema_version == 1 {
        return Ok(Vec::new());
    }
    if schema_version == CURRENT_SCHEMA_VERSION && aad == Some(SEALED_PAYLOAD_AAD) {
        return Ok(format!(
            "{SEALED_PAYLOAD_AAD}|{algorithm}|keyVersion={key_version}|vaultKeyID={vault_key_id}"
        )
        .into_bytes());
    }
    generic_source_aad(schema_version, aad, context)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;
    use std::io;

    fn fixture() -> Result<serde_json::Value, serde_json::Error> {
        serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-document-rewrap-contract.json"
        ))
    }

    fn decode_hex(value: &str) -> Result<Vec<u8>, io::Error> {
        if !value.len().is_multiple_of(2) {
            return Err(io::Error::other("hex fixture must have even length"));
        }
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let text = std::str::from_utf8(pair)
                    .map_err(|_| io::Error::other("hex fixture must be ASCII"))?;
                u8::from_str_radix(text, 16)
                    .map_err(|_| io::Error::other("hex fixture contains non-hex data"))
            })
            .collect()
    }

    const OLD_KEY: [u8; 32] = [0x71; 32];
    const NEW_KEY: [u8; 32] = [0x72; 32];

    fn payload(
        field: &str,
        key: &[u8],
        nonce: &[u8],
        plaintext: &[u8],
    ) -> Result<CloudVaultDocumentEnvelope, CloudVaultError> {
        let key_id = vault_key_id(key)?;
        let aad =
            format!("{SEALED_PAYLOAD_AAD}|{AES_GCM_ALGORITHM}|keyVersion=1|vaultKeyID={key_id}");
        let combined = aes_gcm_seal_combined(plaintext, key, nonce, aad.as_bytes())?;
        Ok(CloudVaultDocumentEnvelope::SealedPayload {
            field_name: field.to_owned(),
            schema_version: 2,
            algorithm: AES_GCM_ALGORITHM.to_owned(),
            key_version: 1,
            vault_key_id: key_id,
            sealed_box_base64: base64_encode(&combined),
            aad: Some(SEALED_PAYLOAD_AAD.to_owned()),
        })
    }

    fn request(envelopes: Vec<CloudVaultDocumentEnvelope>) -> CloudVaultDocumentRewrapRequest {
        CloudVaultDocumentRewrapRequest {
            uid: "userA".to_owned(),
            collection: "missions".to_owned(),
            doc_id: "docA".to_owned(),
            document_field_names: vec![
                "plainStatus".to_owned(),
                "vaultKeyID".to_owned(),
                "sealedPayload".to_owned(),
            ],
            envelopes,
            reseal_nonces: vec![vec![0x22; 12]],
            vault_generation: Some(7),
            rotation_job_id: Some("job-7".to_owned()),
        }
    }

    #[test]
    fn whole_document_rewrap_is_sorted_path_bound_and_returns_intents() -> Result<(), Box<dyn Error>>
    {
        let input = request(vec![payload(
            "sealedPayload",
            &OLD_KEY,
            &[0x11; 12],
            b"secret",
        )?]);
        let new_id = vault_key_id(&NEW_KEY)?;
        let result = rewrap_document(&input, &OLD_KEY, &NEW_KEY, &new_id)?;
        assert_eq!(result.changed_fields, ["sealedPayload"]);
        assert_eq!(result.skipped_fields, Vec::<String>::new());
        assert_eq!(result.vault_generation_update, Some(7));
        assert_eq!(result.rotation_job_id_update.as_deref(), Some("job-7"));
        assert_eq!(result.companion_update_intents.len(), 1);
        assert_eq!(
            result.companion_update_intents[0].companion_field_name,
            "vaultKeyID"
        );
        let CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64,
            aad,
            vault_key_id: output_key_id,
            ..
        } = &result.rewrapped_envelopes[0]
        else {
            return Err(io::Error::other("expected payload output").into());
        };
        assert_eq!(output_key_id, &new_id);
        let expected_aad =
            "OpenBurnBar-CloudVault-aad-v2|userA|missions|docA|sealedPayload|2|sealedPayload";
        assert_eq!(aad.as_deref(), Some(expected_aad));
        let opened = aes_gcm_open_combined(
            &base64_decode_strict(sealed_box_base64)?,
            &NEW_KEY,
            expected_aad.as_bytes(),
        )?;
        assert_eq!(opened, b"secret");
        Ok(())
    }

    #[test]
    fn already_new_payload_is_skipped_without_nonce_or_metadata_intent(
    ) -> Result<(), Box<dyn Error>> {
        let mut input = request(vec![payload(
            "sealedPayload",
            &NEW_KEY,
            &[0x11; 12],
            b"new",
        )?]);
        input.reseal_nonces.clear();
        let new_id = vault_key_id(&NEW_KEY)?;
        let result = rewrap_document(&input, &OLD_KEY, &NEW_KEY, &new_id)?;
        assert!(result.changed_fields.is_empty());
        assert_eq!(result.skipped_fields, ["sealedPayload"]);
        assert!(result.rewrapped_envelopes.is_empty());
        assert_eq!(result.vault_generation_update, None);
        assert_eq!(result.rotation_job_id_update, None);
        Ok(())
    }

    #[test]
    fn rejects_duplicate_fields_nonce_reuse_wrong_key_and_tamper() -> Result<(), Box<dyn Error>> {
        let envelope = payload("sealedPayload", &OLD_KEY, &[0x11; 12], b"secret")?;
        let new_id = vault_key_id(&NEW_KEY)?;

        let mut duplicate = request(vec![envelope.clone(), envelope.clone()]);
        duplicate.reseal_nonces.push(vec![0x23; 12]);
        assert_eq!(
            rewrap_document(&duplicate, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidFieldSet)
        );

        let mut reused_nonce = request(vec![envelope.clone()]);
        reused_nonce.reseal_nonces.push(vec![0x22; 12]);
        assert_eq!(
            rewrap_document(&reused_nonce, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidNoncePlan)
        );

        assert_eq!(
            rewrap_document(
                &request(vec![envelope.clone()]),
                &NEW_KEY,
                &NEW_KEY,
                &new_id
            ),
            Err(CloudVaultDocumentRewrapError::InvalidEnvelope)
        );

        let mut tampered = envelope;
        if let CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64, ..
        } = &mut tampered
        {
            let mut bytes = base64_decode_strict(sealed_box_base64)?;
            bytes[12] ^= 1;
            *sealed_box_base64 = base64_encode(&bytes);
        }
        assert_eq!(
            rewrap_document(&request(vec![tampered]), &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::Crypto(
                CloudVaultError::AuthenticationFailed
            ))
        );
        Ok(())
    }

    #[test]
    fn rejects_future_schema_wrong_aad_and_bounds() -> Result<(), Box<dyn Error>> {
        let mut envelope = payload("sealedPayload", &OLD_KEY, &[0x11; 12], b"secret")?;
        if let CloudVaultDocumentEnvelope::SealedPayload { schema_version, .. } = &mut envelope {
            *schema_version = 3;
        }
        let new_id = vault_key_id(&NEW_KEY)?;
        assert_eq!(
            rewrap_document(&request(vec![envelope]), &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidEnvelope)
        );

        let mut aad_mismatch = payload("sealedPayload", &OLD_KEY, &[0x11; 12], b"secret")?;
        if let CloudVaultDocumentEnvelope::SealedPayload { aad, .. } = &mut aad_mismatch {
            *aad = Some("wrong".to_owned());
        }
        assert_eq!(
            rewrap_document(&request(vec![aad_mismatch]), &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::Crypto(
                CloudVaultError::AadMismatch
            ))
        );

        let mut oversized = request(Vec::new());
        oversized.document_field_names = (0..=MAX_DOCUMENT_FIELDS)
            .map(|index| format!("f{index}"))
            .collect();
        oversized.reseal_nonces.clear();
        assert_eq!(
            rewrap_document(&oversized, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::BoundsExceeded)
        );
        Ok(())
    }

    #[test]
    fn skip_path_authenticates_and_preflight_bounds_before_decode() -> Result<(), Box<dyn Error>> {
        let new_id = vault_key_id(&NEW_KEY)?;
        let new_payload = payload("sealedPayload", &NEW_KEY, &[0x11; 12], b"already new")?;

        let mut future = new_payload.clone();
        if let CloudVaultDocumentEnvelope::SealedPayload { schema_version, .. } = &mut future {
            *schema_version = 3;
        }
        let mut future_request = request(vec![future]);
        future_request.reseal_nonces.clear();
        assert_eq!(
            rewrap_document(&future_request, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidEnvelope)
        );

        let mut future_key_version = new_payload.clone();
        if let CloudVaultDocumentEnvelope::SealedPayload { key_version, .. } =
            &mut future_key_version
        {
            *key_version = 2;
        }
        let mut future_key_request = request(vec![future_key_version]);
        future_key_request.reseal_nonces.clear();
        assert_eq!(
            rewrap_document(&future_key_request, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidEnvelope)
        );

        let mut tampered = new_payload.clone();
        if let CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64, ..
        } = &mut tampered
        {
            let mut bytes = base64_decode_strict(sealed_box_base64)?;
            bytes[12] ^= 1;
            *sealed_box_base64 = base64_encode(&bytes);
        }
        let mut tampered_request = request(vec![tampered]);
        tampered_request.reseal_nonces.clear();
        assert_eq!(
            rewrap_document(&tampered_request, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::Crypto(
                CloudVaultError::AuthenticationFailed
            ))
        );

        let mut oversized_encoded = payload("sealedPayload", &OLD_KEY, &[0x11; 12], b"x")?;
        if let CloudVaultDocumentEnvelope::SealedPayload {
            sealed_box_base64, ..
        } = &mut oversized_encoded
        {
            *sealed_box_base64 = "!".repeat(MAX_DOCUMENT_CIPHERTEXT_ENCODED_BYTES + 1);
        }
        assert_eq!(
            rewrap_document(
                &request(vec![oversized_encoded]),
                &OLD_KEY,
                &NEW_KEY,
                &new_id
            ),
            Err(CloudVaultDocumentRewrapError::BoundsExceeded)
        );
        Ok(())
    }

    #[test]
    fn canonical_fixture_is_exact_and_input_order_independent() -> Result<(), Box<dyn Error>> {
        let value = fixture()?;
        let request: CloudVaultDocumentRewrapRequest =
            serde_json::from_value(value["request"].clone())?;
        let expected: CloudVaultDocumentRewrapResult =
            serde_json::from_value(value["expected"].clone())?;
        let old_key = decode_hex(
            value["oldKeyHex"]
                .as_str()
                .ok_or_else(|| io::Error::other("oldKeyHex missing"))?,
        )?;
        let new_key = decode_hex(
            value["newKeyHex"]
                .as_str()
                .ok_or_else(|| io::Error::other("newKeyHex missing"))?,
        )?;
        let new_id = value["newVaultKeyID"]
            .as_str()
            .ok_or_else(|| io::Error::other("newVaultKeyID missing"))?;
        assert_eq!(value["bounds"]["maxDocumentFields"], MAX_DOCUMENT_FIELDS);
        assert_eq!(value["bounds"]["maxFieldNameBytes"], MAX_FIELD_NAME_BYTES);
        assert_eq!(
            value["bounds"]["maxDocumentCiphertextBytes"],
            MAX_DOCUMENT_CIPHERTEXT_BYTES
        );
        assert_eq!(
            rewrap_document(&request, &old_key, &new_key, new_id)?,
            expected
        );

        for offset in 0..request.envelopes.len() {
            let mut permuted = request.clone();
            permuted.envelopes.rotate_left(offset);
            permuted.document_field_names.reverse();
            assert_eq!(
                rewrap_document(&permuted, &old_key, &new_key, new_id)?,
                expected
            );
        }

        let mutation_names: BTreeSet<&str> = value["adversarialCases"]
            .as_array()
            .ok_or_else(|| io::Error::other("adversarialCases missing"))?
            .iter()
            .filter_map(|entry| entry["mutation"].as_str())
            .collect();
        for required in [
            "wrongOldKey",
            "wrongPathAad",
            "tamperedCiphertext",
            "futureEnvelopeSchema",
            "futureKeyVersion",
            "malformedAlreadyNewPayload",
            "tamperedAlreadyNewPayload",
            "duplicateDocumentField",
            "duplicateEnvelopeField",
            "shortNoncePlan",
            "reusedNonce",
            "fieldCountOverBound",
            "fieldNameOverBound",
            "ciphertextAggregateOverBound",
        ] {
            assert!(mutation_names.contains(required));
        }
        Ok(())
    }

    #[test]
    fn adversarial_field_nonce_and_blob_integrity_cases_fail_closed() -> Result<(), Box<dyn Error>>
    {
        let new_id = vault_key_id(&NEW_KEY)?;
        let base = payload("sealedPayload", &OLD_KEY, &[0x11; 12], b"one")?;

        let mut duplicate_document = request(vec![base.clone()]);
        duplicate_document
            .document_field_names
            .push("sealedPayload".to_owned());
        assert_eq!(
            rewrap_document(&duplicate_document, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidFieldSet)
        );

        let second = payload("sealedStatePayload", &OLD_KEY, &[0x12; 12], b"two")?;
        let mut reused_nonce = request(vec![base.clone(), second]);
        reused_nonce
            .document_field_names
            .push("sealedStatePayload".to_owned());
        reused_nonce.reseal_nonces = vec![vec![0x22; 12], vec![0x22; 12]];
        assert_eq!(
            rewrap_document(&reused_nonce, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidNoncePlan)
        );

        let mut short_plan = request(vec![base.clone()]);
        short_plan.reseal_nonces.clear();
        assert_eq!(
            rewrap_document(&short_plan, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::InvalidNoncePlan)
        );

        let oversized_name = "f".repeat(MAX_FIELD_NAME_BYTES + 1);
        let oversized_envelope = payload(&oversized_name, &OLD_KEY, &[0x11; 12], b"x")?;
        let mut oversized_request = request(vec![oversized_envelope]);
        oversized_request.document_field_names = vec![oversized_name];
        assert_eq!(
            rewrap_document(&oversized_request, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::BoundsExceeded)
        );

        let blob_combined = aes_gcm_seal_combined(b"blob", &OLD_KEY, &[0x13; 12], b"")?;
        let bad_blob = CloudVaultDocumentEnvelope::Blob {
            field_name: "sealedSnapshot".to_owned(),
            schema_version: 2,
            algorithm: AES_GCM_ALGORITHM.to_owned(),
            key_version: 1,
            plaintext_sha256: None,
            plaintext_hmac: Some("00".repeat(32)),
            integrity_hash_version: Some(1),
            sealed_box_base64: base64_encode(&blob_combined),
            aad: Some(BLOB_AAD.to_owned()),
            has_created_at: false,
        };
        let mut blob_request = request(vec![bad_blob]);
        blob_request.document_field_names = vec!["sealedSnapshot".to_owned()];
        assert_eq!(
            rewrap_document(&blob_request, &OLD_KEY, &NEW_KEY, &new_id),
            Err(CloudVaultDocumentRewrapError::IntegrityMismatch)
        );
        Ok(())
    }

    #[test]
    fn legacy_v1_payload_text_and_blob_are_migrated_to_path_bound_v2() -> Result<(), Box<dyn Error>>
    {
        let old_id = vault_key_id(&OLD_KEY)?;
        let new_id = vault_key_id(&NEW_KEY)?;
        let payload_combined = aes_gcm_seal_combined(b"payload", &OLD_KEY, &[0x11; 12], b"")?;
        let text = aes_gcm_seal_detached(b"label", &OLD_KEY, &[0x12; 12], b"")?;
        let blob_plaintext = b"blob";
        let blob_combined = aes_gcm_seal_combined(blob_plaintext, &OLD_KEY, &[0x13; 12], b"")?;
        let request = CloudVaultDocumentRewrapRequest {
            uid: "userA".to_owned(),
            collection: "missions".to_owned(),
            doc_id: "docA".to_owned(),
            document_field_names: vec![
                "sealedSnapshot".to_owned(),
                "sealedPayload".to_owned(),
                "sealedDisplayLabel".to_owned(),
            ],
            envelopes: vec![
                CloudVaultDocumentEnvelope::SealedPayload {
                    field_name: "sealedPayload".to_owned(),
                    schema_version: 1,
                    algorithm: AES_GCM_ALGORITHM.to_owned(),
                    key_version: 1,
                    vault_key_id: old_id,
                    sealed_box_base64: base64_encode(&payload_combined),
                    aad: None,
                },
                CloudVaultDocumentEnvelope::SealedText {
                    field_name: "sealedDisplayLabel".to_owned(),
                    schema_version: None,
                    algorithm: AES_GCM_ALGORITHM.to_owned(),
                    key_version: 1,
                    nonce: base64_encode(&text.nonce),
                    ciphertext: base64_encode(&text.ciphertext),
                    tag: base64_encode(&text.tag),
                    aad: None,
                },
                CloudVaultDocumentEnvelope::Blob {
                    field_name: "sealedSnapshot".to_owned(),
                    schema_version: 1,
                    algorithm: AES_GCM_ALGORITHM.to_owned(),
                    key_version: 1,
                    plaintext_sha256: Some(sha256_hex(blob_plaintext)),
                    plaintext_hmac: None,
                    integrity_hash_version: None,
                    sealed_box_base64: base64_encode(&blob_combined),
                    aad: None,
                    has_created_at: false,
                },
            ],
            reseal_nonces: vec![vec![0x21; 12], vec![0x22; 12], vec![0x23; 12]],
            vault_generation: None,
            rotation_job_id: None,
        };
        let result = rewrap_document(&request, &OLD_KEY, &NEW_KEY, &new_id)?;
        assert_eq!(
            result.changed_fields,
            ["sealedDisplayLabel", "sealedPayload", "sealedSnapshot"]
        );
        for envelope in result.rewrapped_envelopes {
            match envelope {
                CloudVaultDocumentEnvelope::SealedPayload {
                    schema_version,
                    aad,
                    ..
                }
                | CloudVaultDocumentEnvelope::Blob {
                    schema_version,
                    aad,
                    ..
                } => {
                    assert_eq!(schema_version, 2);
                    assert!(aad.is_some());
                }
                CloudVaultDocumentEnvelope::SealedText {
                    schema_version,
                    aad,
                    ..
                } => {
                    assert_eq!(schema_version, Some(2));
                    assert!(aad.is_some());
                }
            }
        }
        Ok(())
    }
}
