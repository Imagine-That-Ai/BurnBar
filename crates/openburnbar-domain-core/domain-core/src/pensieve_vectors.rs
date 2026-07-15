use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroize;

const CLOAK_SALT: &[u8] = b"OpenBurnBar-Pensieve-Cloak-Salt-v1";
const CLOAK_REFLECTIONS: usize = 24;
const MAX_VECTOR_DIMENSIONS: usize = 4_096;
const MAX_MODEL_VERSION_BYTES: usize = 256;
const MAX_TEXT_BYTES: usize = 1_048_576;
const QUERY_INSTRUCTION: &str = "Represent this sentence for searching relevant passages: ";

#[derive(Clone, Copy, Debug, Eq, Error, PartialEq)]
pub enum PensieveVectorError {
    #[error("Pensieve vault keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("Pensieve vectors must contain between 1 and 4096 finite coordinates")]
    InvalidVector,
    #[error("Pensieve model versions must be non-empty bounded printable strings")]
    InvalidModelVersion,
    #[error("Pensieve embedding text must not exceed 1048576 UTF-8 bytes")]
    TextTooLarge,
    #[error("Pensieve vector key derivation failed")]
    DerivationFailure,
}

pub fn cloak(
    vector: &[f64],
    vault_key: &[u8],
    model_version: &str,
) -> Result<Vec<f64>, PensieveVectorError> {
    validate_inputs(vector, vault_key, model_version)?;

    let byte_len = CLOAK_REFLECTIONS
        .checked_mul(vector.len())
        .and_then(|value| value.checked_mul(8))
        .and_then(|value| value.checked_add(64))
        .ok_or(PensieveVectorError::InvalidVector)?;
    let info = format!("OpenBurnBar-Pensieve-Cloak-{model_version}-v1");
    // Preserve the shipped Swift/TypeScript/C# stream exactly. Those clients
    // intentionally wrap the one-byte expansion counter after 255 rather than
    // enforcing RFC 5869's 8160-byte output ceiling; a 384-dimensional cloak
    // consumes 73,792 bytes. This is a versioned PRNG, not a general HKDF API.
    let mut key_stream = extended_hmac_stream(vault_key, info.as_bytes(), byte_len)?;

    let mut offset = 0_usize;
    let mut output = vector.to_vec();
    let mut reflection = vec![0.0_f64; vector.len()];
    for _ in 0..CLOAK_REFLECTIONS {
        let mut norm_squared = 0.0_f64;
        for coordinate in &mut reflection {
            let first = next_uniform(&key_stream, &mut offset);
            let second = next_uniform(&key_stream, &mut offset);
            let gaussian = (-2.0 * first.ln()).sqrt() * (2.0 * std::f64::consts::PI * second).cos();
            *coordinate = gaussian;
            norm_squared += gaussian * gaussian;
        }

        let norm = norm_squared.sqrt();
        if norm == 0.0 {
            reflection.fill(0.0);
            reflection[0] = 1.0;
        } else {
            for coordinate in &mut reflection {
                *coordinate /= norm;
            }
        }

        let dot = reflection
            .iter()
            .zip(&output)
            .map(|(left, right)| left * right)
            .sum::<f64>();
        let coefficient = 2.0 * dot;
        for (coordinate, reflection_coordinate) in output.iter_mut().zip(&reflection) {
            *coordinate -= coefficient * reflection_coordinate;
        }
    }

    reflection.zeroize();
    key_stream.zeroize();
    Ok(output)
}

pub fn deterministic_embed(
    text: &str,
    dimensions: usize,
    is_query: bool,
) -> Result<Vec<f64>, PensieveVectorError> {
    if dimensions == 0 || dimensions > MAX_VECTOR_DIMENSIONS {
        return Err(PensieveVectorError::InvalidVector);
    }
    if text.len() > MAX_TEXT_BYTES {
        return Err(PensieveVectorError::TextTooLarge);
    }
    let mut prepared = if is_query {
        format!("{QUERY_INSTRUCTION}{text}")
    } else {
        text.to_owned()
    };
    let mut accumulator = vec![0.0_f64; dimensions];
    for token in prepared
        .to_lowercase()
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|token| token.len() >= 2)
    {
        let digest = Sha256::digest(token.as_bytes());
        let index = (((usize::from(digest[0])) << 8) | usize::from(digest[1])) % dimensions;
        accumulator[index] += if digest[2] & 1 == 0 { 1.0 } else { -1.0 };
    }
    prepared.zeroize();
    let norm = accumulator
        .iter()
        .map(|value| value * value)
        .sum::<f64>()
        .sqrt();
    if norm != 0.0 {
        for coordinate in &mut accumulator {
            *coordinate /= norm;
        }
    }
    Ok(accumulator)
}

pub fn deterministic_embed_and_cloak(
    text: &str,
    dimensions: usize,
    is_query: bool,
    vault_key: &[u8],
    model_version: &str,
) -> Result<Vec<f64>, PensieveVectorError> {
    let mut embedding = deterministic_embed(text, dimensions, is_query)?;
    let result = cloak(&embedding, vault_key, model_version);
    embedding.zeroize();
    result
}

fn validate_inputs(
    vector: &[f64],
    vault_key: &[u8],
    model_version: &str,
) -> Result<(), PensieveVectorError> {
    if vault_key.len() != 32 {
        return Err(PensieveVectorError::InvalidKeyLength);
    }
    if vector.is_empty()
        || vector.len() > MAX_VECTOR_DIMENSIONS
        || vector.iter().any(|coordinate| !coordinate.is_finite())
    {
        return Err(PensieveVectorError::InvalidVector);
    }
    if model_version.is_empty()
        || model_version.len() > MAX_MODEL_VERSION_BYTES
        || !model_version
            .bytes()
            .all(|byte| (0x20..=0x7e).contains(&byte))
    {
        return Err(PensieveVectorError::InvalidModelVersion);
    }
    Ok(())
}

fn extended_hmac_stream(
    input: &[u8],
    info: &[u8],
    length: usize,
) -> Result<Vec<u8>, PensieveVectorError> {
    type HmacSha256 = Hmac<Sha256>;

    let mut extract = HmacSha256::new_from_slice(CLOAK_SALT)
        .map_err(|_| PensieveVectorError::DerivationFailure)?;
    extract.update(input);
    let mut pseudo_random_key = extract.finalize().into_bytes();
    let mut output = Vec::with_capacity(length);
    let mut previous = [0_u8; 32];
    let mut previous_length = 0_usize;
    let mut counter = 1_u8;

    while output.len() < length {
        let mut expand = HmacSha256::new_from_slice(&pseudo_random_key)
            .map_err(|_| PensieveVectorError::DerivationFailure)?;
        expand.update(&previous[..previous_length]);
        expand.update(info);
        expand.update(&[counter]);
        previous.copy_from_slice(&expand.finalize().into_bytes());
        previous_length = previous.len();
        let remaining = length - output.len();
        output.extend_from_slice(&previous[..remaining.min(previous.len())]);
        counter = counter.wrapping_add(1);
    }

    previous.zeroize();
    pseudo_random_key.zeroize();
    Ok(output)
}

fn next_uniform(bytes: &[u8], offset: &mut usize) -> f64 {
    if *offset + 4 > bytes.len() {
        *offset = 0;
    }
    let value = u32::from_be_bytes([
        bytes[*offset],
        bytes[*offset + 1],
        bytes[*offset + 2],
        bytes[*offset + 3],
    ]);
    *offset += 4;
    (f64::from(value) + 0.5) / 4_294_967_296.0
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 32] = [0x42; 32];

    #[test]
    fn cloak_matches_the_published_cross_language_golden_head() -> Result<(), PensieveVectorError> {
        let mut basis = vec![0.0; 384];
        basis[5] = 1.0;
        let result = cloak(&basis, &KEY, "hashing-bow-v1")?;
        let expected = [
            0.024_962_057_620_774_702,
            -0.001_210_098_649_309_873_4,
            0.019_701_701_944_313_31,
            -0.018_762_882_434_022_78,
            0.050_834_395_709_711_204,
            0.836_794_463_499_599_7,
        ];
        for (actual, expected) in result.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
        }
        Ok(())
    }

    #[test]
    fn cloak_preserves_norm_and_inner_product() -> Result<(), PensieveVectorError> {
        let first = deterministic_embed("pensieve repo docs and notes", 384, false)?;
        let second = deterministic_embed("repo documentation knowledge memory", 384, false)?;
        let cloaked_first = cloak(&first, &KEY, "hashing-bow-v1")?;
        let cloaked_second = cloak(&second, &KEY, "hashing-bow-v1")?;
        let dot =
            |left: &[f64], right: &[f64]| left.iter().zip(right).map(|(a, b)| a * b).sum::<f64>();
        assert!((dot(&first, &first) - dot(&cloaked_first, &cloaked_first)).abs() < 1e-12);
        assert!((dot(&first, &second) - dot(&cloaked_first, &cloaked_second)).abs() < 1e-12);
        Ok(())
    }

    #[test]
    fn inputs_are_bounded_and_fail_closed() {
        assert_eq!(
            cloak(&[1.0], &[0; 31], "model"),
            Err(PensieveVectorError::InvalidKeyLength)
        );
        assert_eq!(
            cloak(&[f64::NAN], &KEY, "model"),
            Err(PensieveVectorError::InvalidVector)
        );
        assert_eq!(
            cloak(&[1.0], &KEY, "bad\nmodel"),
            Err(PensieveVectorError::InvalidModelVersion)
        );
        assert_eq!(
            deterministic_embed(&"x".repeat(MAX_TEXT_BYTES + 1), 384, false),
            Err(PensieveVectorError::TextTooLarge)
        );
    }

    #[test]
    fn embed_and_cloak_matches_the_published_cross_language_golden_head(
    ) -> Result<(), PensieveVectorError> {
        let result = deterministic_embed_and_cloak(
            "hosted minimax encrypted session search",
            384,
            false,
            &KEY,
            "hashing-bow-v1",
        )?;
        let expected = [
            -0.060_383_188_036_775_69,
            0.015_806_595_688_146_123,
            -0.018_190_740_055_065_63,
            -0.013_937_252_354_238_351,
            -0.005_114_345_741_968_682,
            0.036_771_803_890_028_42,
        ];
        for (actual, expected) in result.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
        }
        Ok(())
    }
}
