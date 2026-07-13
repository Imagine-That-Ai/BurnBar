use openburnbar_domain_ffi::{
    calculate_token_cost_nano_usd, cloud_vault_aes_gcm_open_combined,
    cloud_vault_aes_gcm_seal_combined, cloud_vault_base64_decode_strict, cloud_vault_base64_encode,
    cloud_vault_escrow_open, cloud_vault_escrow_seal, cloud_vault_key_id,
    cloud_vault_recovery_open_vault_key, cloud_vault_recovery_wrap_vault_key,
    cloud_vault_rewrap_document, cloud_vault_search, cloud_vault_search_analyze,
    hermes_open_combined, hermes_relay_aad, hermes_seal_combined,
    parse_anthropic_rate_limit_headers, parse_claude_statusline_quota, parse_codex_usage_quota,
    parse_cursor_usage_quota, AnthropicCredentialShape, CloudVaultDocumentEnvelope,
    CloudVaultDocumentEnvelopeKind, CloudVaultDocumentRewrapRequest, CloudVaultResealNonce,
    CloudVaultSearchOperation, CloudVaultSearchRequest, HermesAadKind, QuotaParseResult,
    TokenPricingBuckets, TokenPricingRates,
};
use proptest::collection::vec;
use proptest::prelude::*;
use proptest::test_runner::{
    Config, RngAlgorithm, TestCaseError, TestCaseResult, TestRng, TestRunner,
};
use std::error::Error;
use std::fmt::Display;

const CASES: u32 = 96;
const AES_GCM_ALGORITHM: &str = "AES-256-GCM";
const SEALED_PAYLOAD_AAD: &str = "OpenBurnBar-CloudVaultSealedPayload-v2";
const P256_GENERATOR: [u8; 65] = [
    0x04, 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40,
    0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2,
    0x96, 0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e,
    0x16, 0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51,
    0xf5,
];

fn runner(seed: u8) -> TestRunner {
    let config = Config {
        cases: CASES,
        max_shrink_iters: 4_096,
        failure_persistence: None,
        ..Config::default()
    };
    TestRunner::new_with_rng(
        config,
        TestRng::from_seed(RngAlgorithm::ChaCha, &[seed; 32]),
    )
}

fn case_error(error: impl Display) -> TestCaseError {
    TestCaseError::fail(error.to_string())
}

fn safe_identifier(min: usize, max: usize) -> impl Strategy<Value = String> {
    vec(
        prop::sample::select(('a'..='z').collect::<Vec<_>>()),
        min..max,
    )
    .prop_map(|characters| characters.into_iter().collect())
}

fn unicode_text(max: usize) -> impl Strategy<Value = String> {
    vec(any::<char>(), 0..max).prop_map(|characters| characters.into_iter().collect())
}

fn assert_quota_result_is_bounded(result: &QuotaParseResult) -> TestCaseResult {
    prop_assert!(result.snapshot.buckets.len() <= 64);
    for bucket in &result.snapshot.buckets {
        for value in [
            bucket.used_value,
            bucket.limit_value,
            bucket.remaining_value,
            bucket.used_percent,
            bucket.resets_at_unix,
        ]
        .into_iter()
        .flatten()
        {
            prop_assert!(value.is_finite());
        }
    }
    Ok(())
}

#[test]
fn cloudvault_crypto_recovery_and_escrow_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let strategy = (
        vec(any::<u8>(), 0..4_096),
        any::<[u8; 32]>(),
        any::<[u8; 32]>(),
        any::<[u8; 12]>(),
        vec(any::<u8>(), 0..512),
        safe_identifier(20, 80),
    );
    runner(0x11).run(
        &strategy,
        |(plaintext, key, shared_secret, nonce, aad, recovery_key)| {
            let sealed = cloud_vault_aes_gcm_seal_combined(
                plaintext.clone(),
                key.to_vec(),
                nonce.to_vec(),
                aad.clone(),
            )
            .map_err(case_error)?;
            let opened =
                cloud_vault_aes_gcm_open_combined(sealed.clone(), key.to_vec(), aad.clone())
                    .map_err(case_error)?;
            prop_assert_eq!(&opened, &plaintext);

            let encoded = cloud_vault_base64_encode(sealed.clone()).map_err(case_error)?;
            prop_assert_eq!(
                cloud_vault_base64_decode_strict(encoded).map_err(case_error)?,
                sealed
            );

            let wrapped = cloud_vault_recovery_wrap_vault_key(
                key.to_vec(),
                recovery_key.clone(),
                nonce.to_vec(),
            )
            .map_err(case_error)?;
            prop_assert_eq!(
                cloud_vault_recovery_open_vault_key(wrapped.combined, recovery_key)
                    .map_err(case_error)?,
                key
            );

            let escrow = cloud_vault_escrow_seal(
                plaintext.clone(),
                P256_GENERATOR.to_vec(),
                shared_secret.to_vec(),
                nonce.to_vec(),
            )
            .map_err(case_error)?;
            prop_assert_eq!(
                cloud_vault_escrow_open(escrow.clone(), shared_secret.to_vec())
                    .map_err(case_error)?,
                plaintext
            );

            let mut tampered = escrow;
            let Some(last) = tampered.last_mut() else {
                return Err(TestCaseError::fail("escrow wire unexpectedly empty"));
            };
            *last ^= 1;
            prop_assert!(cloud_vault_escrow_open(tampered, shared_secret.to_vec()).is_err());
            Ok(())
        },
    )?;
    Ok(())
}

#[test]
fn cloudvault_search_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let strategy = (unicode_text(1_024), any::<[u8; 32]>(), 0_i32..=128_i32);
    runner(0x22).run(&strategy, |(text, key, limit)| {
        let analysis = cloud_vault_search_analyze(text.clone()).map_err(case_error)?;
        prop_assert!(analysis.normalized_tokens.len() <= 4_096);
        prop_assert!(analysis.exact_phrase_tokens.len() <= 4_096);

        for operation in [
            CloudVaultSearchOperation::Token,
            CloudVaultSearchOperation::Index,
            CloudVaultSearchOperation::Query,
            CloudVaultSearchOperation::Semantic,
        ] {
            let request = CloudVaultSearchRequest {
                operation,
                text: text.clone(),
                vault_key: key.to_vec(),
                limit,
            };
            let first = cloud_vault_search(request.clone()).map_err(case_error)?;
            let second = cloud_vault_search(request).map_err(case_error)?;
            prop_assert_eq!(&first.hashes, &second.hashes);
            prop_assert!(first.hashes.len() <= limit as usize);
            for hash in first.hashes {
                prop_assert_eq!(hash.len(), 32);
                prop_assert!(hash.bytes().all(|byte| byte.is_ascii_hexdigit()));
            }
        }
        Ok(())
    })?;
    Ok(())
}

#[test]
fn cloudvault_document_rewrap_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let strategy = (
        vec(any::<u8>(), 0..8_192),
        any::<[u8; 32]>(),
        any::<[u8; 12]>(),
        any::<[u8; 12]>(),
    );
    runner(0x33).run(
        &strategy,
        |(plaintext, old_key, source_nonce, destination_nonce)| {
            let mut new_key = old_key;
            new_key[0] ^= 0xff;
            let old_key_id = cloud_vault_key_id(old_key.to_vec()).map_err(case_error)?;
            let new_key_id = cloud_vault_key_id(new_key.to_vec()).map_err(case_error)?;
            let source_aad = format!(
                "{SEALED_PAYLOAD_AAD}|{AES_GCM_ALGORITHM}|keyVersion=1|vaultKeyID={old_key_id}"
            );
            let source_box = cloud_vault_aes_gcm_seal_combined(
                plaintext.clone(),
                old_key.to_vec(),
                source_nonce.to_vec(),
                source_aad.into_bytes(),
            )
            .map_err(case_error)?;
            let request = CloudVaultDocumentRewrapRequest {
                uid: "userA".to_owned(),
                collection: "missions".to_owned(),
                doc_id: "docA".to_owned(),
                document_field_names: vec!["sealedPayload".to_owned(), "vaultKeyID".to_owned()],
                envelopes: vec![CloudVaultDocumentEnvelope {
                    kind: CloudVaultDocumentEnvelopeKind::SealedPayload,
                    field_name: "sealedPayload".to_owned(),
                    schema_version: Some(2),
                    algorithm: AES_GCM_ALGORITHM.to_owned(),
                    key_version: 1,
                    vault_key_id: Some(old_key_id),
                    nonce: None,
                    ciphertext: None,
                    tag: None,
                    sealed_box_base64: Some(
                        cloud_vault_base64_encode(source_box).map_err(case_error)?,
                    ),
                    plaintext_sha256: None,
                    plaintext_hmac: None,
                    integrity_hash_version: None,
                    aad: Some(SEALED_PAYLOAD_AAD.to_owned()),
                    has_created_at: false,
                }],
                reseal_nonce_plan: vec![CloudVaultResealNonce {
                    field_name: "sealedPayload".to_owned(),
                    nonce: destination_nonce.to_vec(),
                }],
                vault_generation: Some(2),
                rotation_job_id: Some("property-job".to_owned()),
            };
            let result = cloud_vault_rewrap_document(
                request,
                old_key.to_vec(),
                new_key.to_vec(),
                new_key_id,
            )
            .map_err(case_error)?;
            prop_assert_eq!(&result.changed_fields, &["sealedPayload"]);
            prop_assert!(result.skipped_fields.is_empty());
            prop_assert_eq!(result.rewrapped_envelopes.len(), 1);
            let output = &result.rewrapped_envelopes[0];
            let sealed = output
                .sealed_box_base64
                .clone()
                .ok_or_else(|| TestCaseError::fail("rewrap output omitted sealed box"))?;
            let output_aad = output
                .aad
                .clone()
                .ok_or_else(|| TestCaseError::fail("rewrap output omitted AAD"))?;
            prop_assert_eq!(
                cloud_vault_aes_gcm_open_combined(
                    cloud_vault_base64_decode_strict(sealed).map_err(case_error)?,
                    new_key.to_vec(),
                    output_aad.into_bytes(),
                )
                .map_err(case_error)?,
                plaintext
            );
            Ok(())
        },
    )?;
    Ok(())
}

#[test]
fn quota_payload_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let strategy = (vec(any::<u8>(), 0..65_536), any::<i64>(), any::<bool>());
    runner(0x44).run(&strategy, |(payload, now_unix, oauth)| {
        let shape = if oauth {
            AnthropicCredentialShape::OauthBearer
        } else {
            AnthropicCredentialShape::ConsoleApiKey
        };
        for result in [
            parse_claude_statusline_quota(payload.clone()),
            parse_codex_usage_quota(payload.clone(), now_unix),
            parse_cursor_usage_quota(payload.clone(), None),
            parse_anthropic_rate_limit_headers(payload, now_unix, shape),
        ] {
            assert_quota_result_is_bounded(&result)?;
        }
        Ok(())
    })?;
    Ok(())
}

#[test]
fn hermes_payload_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let strategy = (
        vec(any::<u8>(), 0..8_192),
        any::<[u8; 32]>(),
        any::<[u8; 12]>(),
        safe_identifier(1, 64),
        safe_identifier(1, 64),
        safe_identifier(1, 64),
    );
    runner(0x55).run(
        &strategy,
        |(plaintext, key, nonce, first, second, third)| {
            let aad = hermes_relay_aad(HermesAadKind::Request, vec![first, second, third])
                .map_err(case_error)?;
            let sealed =
                hermes_seal_combined(plaintext.clone(), key.to_vec(), aad.clone(), nonce.to_vec())
                    .map_err(case_error)?;
            prop_assert_eq!(
                hermes_open_combined(sealed.clone(), key.to_vec(), aad.clone())
                    .map_err(case_error)?,
                plaintext
            );
            let mut tampered = sealed;
            let Some(last) = tampered.last_mut() else {
                return Err(TestCaseError::fail("Hermes wire unexpectedly empty"));
            };
            *last ^= 1;
            prop_assert!(hermes_open_combined(tampered, key.to_vec(), aad).is_err());
            Ok(())
        },
    )?;
    Ok(())
}

#[test]
fn pricing_arithmetic_fuzz_smoke() -> Result<(), Box<dyn Error>> {
    let rate = 0_u64..=1_000_000_000_000_u64;
    let tokens = 0_u64..=1_000_000_000_000_u64;
    let strategy = (
        (
            rate.clone(),
            rate.clone(),
            proptest::option::of(rate.clone()),
            rate,
        ),
        (tokens.clone(), tokens.clone(), tokens.clone(), tokens),
    );
    runner(0x66).run(
        &strategy,
        |((input_rate, output_rate, creation_rate, read_rate), buckets)| {
            let rates = TokenPricingRates {
                input_nano_usd_per_m_token: input_rate,
                output_nano_usd_per_m_token: output_rate,
                cache_creation_nano_usd_per_m_token: creation_rate,
                cache_read_nano_usd_per_m_token: read_rate,
            };
            let buckets = TokenPricingBuckets {
                input_tokens: buckets.0,
                output_tokens: buckets.1,
                cache_creation_tokens: buckets.2,
                cache_read_tokens: buckets.3,
            };
            let expected_numerator = u128::from(buckets.input_tokens) * u128::from(input_rate)
                + u128::from(buckets.output_tokens) * u128::from(output_rate)
                + u128::from(buckets.cache_creation_tokens)
                    * u128::from(creation_rate.unwrap_or(input_rate))
                + u128::from(buckets.cache_read_tokens) * u128::from(read_rate);
            let expected = (expected_numerator + 500_000) / 1_000_000;
            prop_assert_eq!(
                u128::from(calculate_token_cost_nano_usd(rates, buckets).map_err(case_error)?),
                expected
            );
            Ok(())
        },
    )?;
    Ok(())
}
