use openburnbar_domain_ffi::{
    cloud_vault_aes_gcm_open_combined, cloud_vault_aes_gcm_seal_combined,
    cloud_vault_base64_encode, cloud_vault_key_id, cloud_vault_rewrap_document, cloud_vault_search,
    parse_claude_statusline_quota, CloudVaultDocumentEnvelope, CloudVaultDocumentEnvelopeKind,
    CloudVaultDocumentRewrapRequest, CloudVaultResealNonce, CloudVaultSearchOperation,
    CloudVaultSearchRequest,
};
use std::error::Error;
use std::hint::black_box;
use std::io;
use std::time::{Duration, Instant};

const AES_GCM_ALGORITHM: &str = "AES-256-GCM";
const SEALED_PAYLOAD_AAD: &str = "OpenBurnBar-CloudVaultSealedPayload-v2";

struct RewrapBenchmarkInput {
    request: CloudVaultDocumentRewrapRequest,
    old_key: Vec<u8>,
    new_key: Vec<u8>,
    new_key_id: String,
}

fn measure_payload_boundary(
    name: &str,
    iterations: usize,
    bytes_per_iteration: usize,
    maximum_p95: Duration,
    mut operation: impl FnMut() -> Result<(), Box<dyn Error>>,
) -> Result<(), Box<dyn Error>> {
    let mut samples = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let started = Instant::now();
        operation()?;
        samples.push(started.elapsed());
    }
    samples.sort_unstable();
    let p95_index = (samples.len() * 95).div_ceil(100).saturating_sub(1);
    let p95 = samples
        .get(p95_index)
        .copied()
        .ok_or_else(|| io::Error::other("performance smoke requires at least one sample"))?;
    let total_bytes = bytes_per_iteration.saturating_mul(iterations);
    let elapsed_seconds = samples.iter().map(Duration::as_secs_f64).sum::<f64>();
    let mib_per_second = if elapsed_seconds > 0.0 {
        total_bytes as f64 / (1024.0 * 1024.0) / elapsed_seconds
    } else {
        f64::INFINITY
    };
    println!(
        "domain-core-perf name={name} iterations={iterations} payload_bytes={bytes_per_iteration} p95_ms={:.3} throughput_mib_s={mib_per_second:.3}",
        p95.as_secs_f64() * 1_000.0,
    );
    if p95 > maximum_p95 {
        return Err(io::Error::other(format!(
            "{name} complete-payload p95 {p95:?} exceeded catastrophic guard {maximum_p95:?}"
        ))
        .into());
    }
    Ok(())
}

fn rewrap_request() -> Result<RewrapBenchmarkInput, Box<dyn Error>> {
    let old_key = vec![0x71; 32];
    let new_key = vec![0x72; 32];
    let old_key_id = cloud_vault_key_id(old_key.clone())?;
    let new_key_id = cloud_vault_key_id(new_key.clone())?;
    let source_aad =
        format!("{SEALED_PAYLOAD_AAD}|{AES_GCM_ALGORITHM}|keyVersion=1|vaultKeyID={old_key_id}");
    let plaintext = vec![0x5a; 4 * 1024];
    let mut document_field_names = vec!["vaultKeyID".to_owned()];
    let mut envelopes = Vec::with_capacity(32);
    let mut reseal_nonce_plan = Vec::with_capacity(32);
    for index in 0_u32..32 {
        let field_name = format!("sealedField{index:02}");
        document_field_names.push(field_name.clone());
        let mut source_nonce = [0x11; 12];
        source_nonce[8..].copy_from_slice(&index.to_be_bytes());
        let mut destination_nonce = [0x22; 12];
        destination_nonce[8..].copy_from_slice(&index.to_be_bytes());
        let source_box = cloud_vault_aes_gcm_seal_combined(
            plaintext.clone(),
            old_key.clone(),
            source_nonce.to_vec(),
            source_aad.as_bytes().to_vec(),
        )?;
        envelopes.push(CloudVaultDocumentEnvelope {
            kind: CloudVaultDocumentEnvelopeKind::SealedPayload,
            field_name: field_name.clone(),
            schema_version: Some(2),
            algorithm: AES_GCM_ALGORITHM.to_owned(),
            key_version: 1,
            vault_key_id: Some(old_key_id.clone()),
            nonce: None,
            ciphertext: None,
            tag: None,
            sealed_box_base64: Some(cloud_vault_base64_encode(source_box)?),
            plaintext_sha256: None,
            plaintext_hmac: None,
            integrity_hash_version: None,
            aad: Some(SEALED_PAYLOAD_AAD.to_owned()),
            has_created_at: false,
        });
        reseal_nonce_plan.push(CloudVaultResealNonce {
            field_name,
            nonce: destination_nonce.to_vec(),
        });
    }
    Ok(RewrapBenchmarkInput {
        request: CloudVaultDocumentRewrapRequest {
            uid: "benchmark-user".to_owned(),
            collection: "missions".to_owned(),
            doc_id: "benchmark-document".to_owned(),
            document_field_names,
            envelopes,
            reseal_nonce_plan,
            vault_generation: Some(2),
            rotation_job_id: Some("benchmark-rotation".to_owned()),
        },
        old_key,
        new_key,
        new_key_id,
    })
}

#[test]
#[ignore = "release-mode CI smoke; run with the command documented in the crate README"]
fn complete_payload_ffi_performance_smoke() -> Result<(), Box<dyn Error>> {
    let padding = "a".repeat(512 * 1024);
    let quota_payload = format!(r#"{{"rate_limits":[],"padding":"{padding}"}}"#).into_bytes();
    measure_payload_boundary(
        "quota-response",
        24,
        quota_payload.len(),
        Duration::from_millis(500),
        || {
            black_box(parse_claude_statusline_quota(quota_payload.clone()));
            Ok(())
        },
    )?;

    let search_text = "a".repeat(256 * 1024);
    let search_key = vec![0x5a; 32];
    measure_payload_boundary(
        "search-query",
        12,
        search_text.len(),
        Duration::from_secs(1),
        || {
            black_box(cloud_vault_search(CloudVaultSearchRequest {
                operation: CloudVaultSearchOperation::Query,
                text: search_text.clone(),
                vault_key: search_key.clone(),
                limit: 64,
            })?);
            Ok(())
        },
    )?;

    let plaintext = vec![0x3c; 1024 * 1024];
    let crypto_key = vec![0x4d; 32];
    let crypto_nonce = vec![0x5e; 12];
    let crypto_aad = b"complete-payload-performance-smoke".to_vec();
    measure_payload_boundary(
        "aes-seal-open",
        12,
        plaintext.len() * 2,
        Duration::from_secs(1),
        || {
            let sealed = cloud_vault_aes_gcm_seal_combined(
                plaintext.clone(),
                crypto_key.clone(),
                crypto_nonce.clone(),
                crypto_aad.clone(),
            )?;
            black_box(cloud_vault_aes_gcm_open_combined(
                sealed,
                crypto_key.clone(),
                crypto_aad.clone(),
            )?);
            Ok(())
        },
    )?;

    let rewrap = rewrap_request()?;
    measure_payload_boundary(
        "document-rewrap",
        12,
        32 * 4 * 1024,
        Duration::from_secs(2),
        || {
            let result = cloud_vault_rewrap_document(
                rewrap.request.clone(),
                rewrap.old_key.clone(),
                rewrap.new_key.clone(),
                rewrap.new_key_id.clone(),
            )?;
            if result.changed_fields.len() != 32 {
                return Err(
                    io::Error::other("rewrap benchmark returned incomplete intents").into(),
                );
            }
            black_box(result);
            Ok(())
        },
    )?;
    Ok(())
}
