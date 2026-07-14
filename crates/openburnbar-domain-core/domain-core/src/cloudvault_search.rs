use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::collections::HashSet;
use zeroize::{Zeroize, Zeroizing};

const SEARCH_SALT: &[u8] = b"OpenBurnBar-CloudSearch-Salt-v1";
const SEARCH_INFO: &[u8] = b"OpenBurnBar-CloudSearch-TokenHash-v1";
const SEMANTIC_SEARCH_SALT: &[u8] = b"OpenBurnBar-CloudSearch-Semantic-Salt-v1";
const SEMANTIC_SEARCH_INFO: &[u8] = b"OpenBurnBar-CloudSearch-SemanticHash-v1";
const SEARCH_KEY_LENGTH: usize = 32;
const HASH_OUTPUT_LENGTH: usize = 16;
const SEMANTIC_DIMENSIONS: usize = 64;
const SEMANTIC_BAND_SIZE: usize = 8;
const MIN_INDEX_PREFIX_LENGTH: usize = 3;
const MAX_PREFIX_LENGTH: usize = 16;
const SEMANTIC_PREFIX_LENGTH: usize = 5;

pub const MAX_SEARCH_TEXT_BYTES: usize = 1_048_576;
pub const MAX_SEARCH_LIMIT: i32 = 1_024;
pub const MAX_SEARCH_TOKENS: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloudVaultSearchOperation {
    Token,
    Index,
    Query,
    Semantic,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CloudVaultSearchAnalysis {
    pub normalized_tokens: Vec<String>,
    pub exact_phrase_tokens: Vec<String>,
    pub semantic_features: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CloudVaultSearchResult {
    pub operation: CloudVaultSearchOperation,
    pub hashes: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, thiserror::Error)]
pub enum CloudVaultSearchError {
    #[error("cloud vault search keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("cloud vault search text exceeds 1048576 UTF-8 bytes")]
    TextTooLarge,
    #[error("cloud vault search limits must not exceed 1024")]
    LimitTooLarge,
    #[error("cloud vault search input exceeds 4096 extracted tokens")]
    TooManyTokens,
    #[error("cloud vault search key derivation failed")]
    DerivationFailure,
}

pub fn analyze(text: &str) -> Result<CloudVaultSearchAnalysis, CloudVaultSearchError> {
    validate_text(text)?;
    let mut normalized_tokens = Zeroizing::new(tokenize(text, false)?);
    let mut exact_phrase_tokens = Zeroizing::new(tokenize(text, true)?);
    let semantic_features = semantic_features(&exact_phrase_tokens)
        .into_iter()
        .map(|feature| feature.name)
        .collect();
    Ok(CloudVaultSearchAnalysis {
        normalized_tokens: std::mem::take(&mut *normalized_tokens),
        exact_phrase_tokens: std::mem::take(&mut *exact_phrase_tokens),
        semantic_features,
    })
}

pub fn search(
    operation: CloudVaultSearchOperation,
    text: &str,
    vault_key: &[u8],
    limit: i32,
) -> Result<CloudVaultSearchResult, CloudVaultSearchError> {
    validate_text(text)?;
    if vault_key.len() != SEARCH_KEY_LENGTH {
        return Err(CloudVaultSearchError::InvalidKeyLength);
    }
    if limit > MAX_SEARCH_LIMIT {
        return Err(CloudVaultSearchError::LimitTooLarge);
    }
    if limit <= 0 {
        return Ok(CloudVaultSearchResult {
            operation,
            hashes: Vec::new(),
        });
    }
    let limit = usize::try_from(limit).map_err(|_| CloudVaultSearchError::LimitTooLarge)?;

    let hashes = match operation {
        CloudVaultSearchOperation::Token => {
            let tokens = Zeroizing::new(tokenize(text, false)?);
            token_hashes(&tokens, vault_key, limit)?
        }
        CloudVaultSearchOperation::Index => {
            let tokens = Zeroizing::new(unique(tokenize(text, false)?));
            let mut terms = Zeroizing::new(tokens.to_vec());
            terms.extend(search_index_prefix_terms(&tokens));
            terms.extend(exact_phrase_terms(text)?);
            token_hashes(&terms, vault_key, limit)?
        }
        CloudVaultSearchOperation::Query => {
            let tokens = Zeroizing::new(unique(tokenize(text, false)?));
            let mut terms = Zeroizing::new(tokens.to_vec());
            terms.extend(
                tokens
                    .iter()
                    .filter_map(|token| search_query_prefix_term(token)),
            );
            terms.extend(exact_phrase_terms(text)?);
            token_hashes(&terms, vault_key, limit)?
        }
        CloudVaultSearchOperation::Semantic => semantic_hashes(text, vault_key, limit)?,
    };

    Ok(CloudVaultSearchResult { operation, hashes })
}

fn validate_text(text: &str) -> Result<(), CloudVaultSearchError> {
    if text.len() > MAX_SEARCH_TEXT_BYTES {
        Err(CloudVaultSearchError::TextTooLarge)
    } else {
        Ok(())
    }
}

fn tokenize(text: &str, include_x: bool) -> Result<Vec<String>, CloudVaultSearchError> {
    let lowered = Zeroizing::new(text.to_lowercase());
    let mut tokens = Zeroizing::new(Vec::new());
    let mut current = Zeroizing::new(String::new());
    for character in lowered.chars().chain(std::iter::once(' ')) {
        if character.is_alphanumeric() {
            current.push(character);
            continue;
        }
        if !current.is_empty() {
            let keep = (current.chars().count() >= 2 || (include_x && current.as_str() == "x"))
                && !is_stopword(&current);
            if keep {
                tokens.push(std::mem::take(&mut *current));
                if tokens.len() > MAX_SEARCH_TOKENS {
                    return Err(CloudVaultSearchError::TooManyTokens);
                }
            } else {
                current.clear();
            }
        }
    }
    Ok(std::mem::take(&mut *tokens))
}

fn is_stopword(token: &str) -> bool {
    matches!(
        token,
        "the"
            | "and"
            | "for"
            | "with"
            | "that"
            | "this"
            | "from"
            | "how"
            | "what"
            | "where"
            | "when"
            | "why"
            | "are"
            | "was"
            | "were"
            | "you"
            | "your"
            | "have"
            | "has"
            | "had"
            | "into"
            | "onto"
            | "can"
            | "could"
            | "should"
            | "would"
    )
}

fn unique(values: Vec<String>) -> Vec<String> {
    let values = Zeroizing::new(values);
    let mut seen = HashSet::new();
    values
        .iter()
        .filter(|value| seen.insert(value.as_str()))
        .cloned()
        .collect()
}

fn search_index_prefix_terms(tokens: &[String]) -> Vec<String> {
    let mut terms = Vec::new();
    for token in tokens {
        let characters = Zeroizing::new(token.chars().collect::<Vec<char>>());
        if characters.len() < MIN_INDEX_PREFIX_LENGTH + 1 {
            continue;
        }
        let max_length = MAX_PREFIX_LENGTH.min(characters.len() - 1);
        for length in MIN_INDEX_PREFIX_LENGTH..=max_length {
            terms.push(format!(
                "prefix:v1:{}",
                characters[..length].iter().collect::<String>()
            ));
        }
    }
    terms
}

fn search_query_prefix_term(token: &str) -> Option<String> {
    let characters = Zeroizing::new(token.chars().collect::<Vec<char>>());
    if characters.len() < MIN_INDEX_PREFIX_LENGTH {
        return None;
    }
    Some(format!(
        "prefix:v1:{}",
        characters[..MAX_PREFIX_LENGTH.min(characters.len())]
            .iter()
            .collect::<String>()
    ))
}

fn exact_phrase_terms(text: &str) -> Result<Vec<String>, CloudVaultSearchError> {
    let tokens = Zeroizing::new(tokenize(text, true)?);
    if tokens.len() < 2 {
        return Ok(Vec::new());
    }
    let mut terms = Vec::with_capacity(tokens.len().saturating_mul(2));
    for index in 0..tokens.len() {
        if index + 1 < tokens.len() {
            terms.push(format!("phrase:v1:{}_{}", tokens[index], tokens[index + 1]));
        }
        if index + 2 < tokens.len() {
            terms.push(format!(
                "phrase:v1:{}_{}_{}",
                tokens[index],
                tokens[index + 1],
                tokens[index + 2]
            ));
        }
    }
    Ok(terms)
}

fn token_hashes(
    terms: &[String],
    vault_key: &[u8],
    limit: usize,
) -> Result<Vec<String>, CloudVaultSearchError> {
    let search_key = Zeroizing::new(derive_key(vault_key, SEARCH_SALT, SEARCH_INFO)?);
    let mut seen = HashSet::new();
    let mut hashes = Vec::with_capacity(limit.min(terms.len()));
    for term in terms {
        if !seen.insert(term.as_str()) {
            continue;
        }
        hashes.push(hmac_truncated_hex(search_key.as_slice(), term.as_bytes())?);
        if hashes.len() >= limit {
            break;
        }
    }
    Ok(hashes)
}

#[derive(Clone, Debug)]
struct SemanticFeature {
    name: String,
    weight: f64,
}

impl Zeroize for SemanticFeature {
    fn zeroize(&mut self) {
        self.name.zeroize();
        self.weight.zeroize();
    }
}

fn semantic_hashes(
    text: &str,
    vault_key: &[u8],
    limit: usize,
) -> Result<Vec<String>, CloudVaultSearchError> {
    let tokens = Zeroizing::new(tokenize(text, true)?);
    if tokens.is_empty() {
        return Ok(Vec::new());
    }
    let features = Zeroizing::new(semantic_features(&tokens));
    if features.is_empty() {
        return Ok(Vec::new());
    }
    let search_key = Zeroizing::new(derive_key(
        vault_key,
        SEMANTIC_SEARCH_SALT,
        SEMANTIC_SEARCH_INFO,
    )?);
    let mut accumulator = Zeroizing::new([0.0_f64; SEMANTIC_DIMENSIONS]);
    for feature in features.iter() {
        let mut digest = hmac_sha256(search_key.as_slice(), feature.name.as_bytes())?;
        let index = ((usize::from(digest[0]) << 8) | usize::from(digest[1])) % SEMANTIC_DIMENSIONS;
        let sign = if digest[2] & 1 == 0 { 1.0 } else { -1.0 };
        accumulator[index] += sign * feature.weight;
        digest.zeroize();
    }

    let mut hashes = Vec::with_capacity(limit);
    let mut seen = HashSet::new();
    for band in 0..(SEMANTIC_DIMENSIONS / SEMANTIC_BAND_SIZE) {
        let mut value = 0_u8;
        for bit in 0..SEMANTIC_BAND_SIZE {
            if accumulator[band * SEMANTIC_BAND_SIZE + bit] >= 0.0 {
                value |= 1 << bit;
            }
        }
        append_hash_bucket(
            &mut hashes,
            &mut seen,
            limit,
            search_key.as_slice(),
            format!("simhash:v1:band:{band}:{value:02x}"),
        )?;
    }
    for feature in features.iter() {
        if hashes.len() >= limit {
            break;
        }
        append_hash_bucket(
            &mut hashes,
            &mut seen,
            limit,
            search_key.as_slice(),
            format!("feature:v1:{}", feature.name),
        )?;
    }
    Ok(hashes)
}

fn append_hash_bucket(
    hashes: &mut Vec<String>,
    seen: &mut HashSet<String>,
    limit: usize,
    search_key: &[u8],
    bucket: String,
) -> Result<(), CloudVaultSearchError> {
    if hashes.len() >= limit {
        return Ok(());
    }
    let bucket = Zeroizing::new(bucket);
    let hash = hmac_truncated_hex(search_key, bucket.as_bytes())?;
    if seen.insert(hash.clone()) {
        hashes.push(hash);
    }
    Ok(())
}

fn semantic_features(tokens: &[String]) -> Vec<SemanticFeature> {
    let mut features = Vec::new();
    let mut seen = HashSet::new();
    {
        let mut append = |name: String, weight: f64| {
            if !name.is_empty() && seen.insert(name.clone()) {
                features.push(SemanticFeature { name, weight });
            }
        };

        for concept in semantic_concepts(tokens) {
            append(format!("concept:{concept}"), 3.2);
        }
        for token in tokens {
            append(format!("token:{token}"), 2.4);
            let mut stem = simple_semantic_stem(token);
            if stem.as_str() != token {
                append(format!("stem:{stem}"), 1.8);
            }
            stem.zeroize();
            let characters = Zeroizing::new(token.chars().collect::<Vec<char>>());
            if characters.len() >= SEMANTIC_PREFIX_LENGTH {
                append(
                    format!(
                        "prefix:{}",
                        characters[..SEMANTIC_PREFIX_LENGTH]
                            .iter()
                            .collect::<String>()
                    ),
                    0.8,
                );
            }
        }
        for pair in tokens.windows(2) {
            append(format!("bigram:{}_{}", pair[0], pair[1]), 1.3);
        }
    }
    for mut name in seen.drain() {
        name.zeroize();
    }
    features
}

fn semantic_concepts(tokens: &[String]) -> Vec<&'static str> {
    let mut concepts = Vec::new();
    let mut seen = HashSet::new();
    for token in tokens {
        match token.as_str() {
            "x" | "twitter" | "tweets" | "tweet" | "xcom" => {
                append_concept(&mut concepts, &mut seen, "x-platform");
                append_concept(&mut concepts, &mut seen, "social-platform");
            }
            "ads" | "ad" | "advertising" | "advertise" | "campaign" | "campaigns" | "marketing" => {
                append_concept(&mut concepts, &mut seen, "advertising")
            }
            "api" | "apis" | "endpoint" | "endpoints" | "sdk" | "webhook" | "webhooks"
            | "integration" | "integrations" => {
                append_concept(&mut concepts, &mut seen, "api-integration")
            }
            "oauth" | "auth" | "login" | "signin" | "token" | "tokens" | "credential"
            | "credentials" => append_concept(&mut concepts, &mut seen, "authentication"),
            "billing" | "invoice" | "invoices" | "pricing" | "price" | "cost" | "spend"
            | "quota" | "usage" => append_concept(&mut concepts, &mut seen, "billing-usage"),
            "backup" | "sync" | "mirror" | "cache" | "restore" | "download" | "upload" => {
                append_concept(&mut concepts, &mut seen, "backup-sync")
            }
            _ => {}
        }
    }
    if seen.contains("x-platform") && seen.contains("advertising") {
        append_concept(&mut concepts, &mut seen, "x-ads");
    }
    if seen.contains("advertising") && seen.contains("api-integration") {
        append_concept(&mut concepts, &mut seen, "ads-api");
    }
    if seen.contains("x-platform") && seen.contains("api-integration") {
        append_concept(&mut concepts, &mut seen, "x-api");
    }
    concepts
}

fn append_concept(
    concepts: &mut Vec<&'static str>,
    seen: &mut HashSet<&'static str>,
    concept: &'static str,
) {
    if seen.insert(concept) {
        concepts.push(concept);
    }
}

fn simple_semantic_stem(token: &str) -> String {
    const SUFFIXES: [&str; 14] = [
        "ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers",
        "er", "ed", "s",
    ];
    let token_length = token.chars().count();
    for suffix in SUFFIXES {
        if token_length > suffix.chars().count() + 3 && token.ends_with(suffix) {
            let stem = token.strip_suffix(suffix).unwrap_or(token);
            return if matches!(suffix, "ies" | "ied") {
                format!("{stem}y")
            } else {
                stem.to_owned()
            };
        }
    }
    token.to_owned()
}

fn derive_key(
    vault_key: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; SEARCH_KEY_LENGTH], CloudVaultSearchError> {
    let mut output = Zeroizing::new([0_u8; SEARCH_KEY_LENGTH]);
    Hkdf::<Sha256>::new(Some(salt), vault_key)
        .expand(info, &mut *output)
        .map_err(|_| CloudVaultSearchError::DerivationFailure)?;
    Ok(*output)
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Result<[u8; 32], CloudVaultSearchError> {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key)
        .map_err(|_| CloudVaultSearchError::DerivationFailure)?;
    mac.update(data);
    Ok(mac.finalize().into_bytes().into())
}

fn hmac_truncated_hex(key: &[u8], data: &[u8]) -> Result<String, CloudVaultSearchError> {
    let mut digest = hmac_sha256(key, data)?;
    let output = hex_lower(&digest[..HASH_OUTPUT_LENGTH]);
    digest.zeroize();
    Ok(output)
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

    fn fixture() -> Result<Value, serde_json::Error> {
        serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/cloudvault/v1/cloudvault-search-contract.json"
        ))
    }

    fn required_string<'a>(value: &'a Value, key: &str) -> Result<&'a str, io::Error> {
        value[key]
            .as_str()
            .ok_or_else(|| io::Error::other(format!("fixture field {key} must be a string")))
    }

    fn decode_hex(value: &str) -> Result<Vec<u8>, io::Error> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| {
                let text = std::str::from_utf8(pair)
                    .map_err(|_| io::Error::other("hex fixture must be ASCII"))?;
                u8::from_str_radix(text, 16)
                    .map_err(|_| io::Error::other("fixture contains non-hex data"))
            })
            .collect()
    }

    fn strings(value: &Value) -> Result<Vec<String>, io::Error> {
        value
            .as_array()
            .ok_or_else(|| io::Error::other("fixture field must be an array"))?
            .iter()
            .map(|item| {
                item.as_str()
                    .map(ToOwned::to_owned)
                    .ok_or_else(|| io::Error::other("fixture array item must be a string"))
            })
            .collect()
    }

    fn generated_text(case: &Value) -> Result<String, io::Error> {
        if let Some(text) = case["text"].as_str() {
            return Ok(text.to_owned());
        }
        let input = &case["input"];
        if input["kind"] != "numberedTokens" {
            return Err(io::Error::other("unknown generated fixture input"));
        }
        let prefix = required_string(input, "prefix")?;
        let count = input["count"]
            .as_u64()
            .ok_or_else(|| io::Error::other("generated input count must be unsigned"))?;
        Ok((0..count)
            .map(|index| format!("{prefix}{index}"))
            .collect::<Vec<_>>()
            .join(" "))
    }

    #[test]
    fn analysis_matches_canonical_contract() -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        for case in fixture["tokenizationCases"]
            .as_array()
            .ok_or_else(|| io::Error::other("tokenizationCases must be an array"))?
        {
            let analysis = analyze(required_string(case, "text")?)?;
            assert_eq!(
                analysis.normalized_tokens,
                strings(&case["normalizedTokens"])?
            );
            assert_eq!(
                analysis.exact_phrase_tokens,
                strings(&case["exactPhraseTokens"])?
            );
        }
        for case in fixture["semanticFeatureCases"]
            .as_array()
            .ok_or_else(|| io::Error::other("semanticFeatureCases must be an array"))?
        {
            assert_eq!(
                analyze(required_string(case, "text")?)?.semantic_features,
                strings(&case["features"])?
            );
        }
        Ok(())
    }

    #[test]
    fn hashes_match_every_canonical_case() -> Result<(), Box<dyn std::error::Error>> {
        let fixture = fixture()?;
        let primary = decode_hex(required_string(&fixture, "primaryKeyHex")?)?;
        let alternate = decode_hex(required_string(&fixture, "alternateKeyHex")?)?;
        for case in fixture["hashCases"]
            .as_array()
            .ok_or_else(|| io::Error::other("hashCases must be an array"))?
        {
            let operation = match required_string(case, "operation")? {
                "token" => CloudVaultSearchOperation::Token,
                "index" => CloudVaultSearchOperation::Index,
                "query" => CloudVaultSearchOperation::Query,
                "semantic" => CloudVaultSearchOperation::Semantic,
                value => return Err(io::Error::other(format!("unknown operation {value}")).into()),
            };
            let key = match required_string(case, "key")? {
                "primary" => &primary,
                "alternate" => &alternate,
                value => return Err(io::Error::other(format!("unknown key {value}")).into()),
            };
            let limit = case["limit"]
                .as_i64()
                .and_then(|value| i32::try_from(value).ok())
                .ok_or_else(|| io::Error::other("limit must fit i32"))?;
            let actual = search(operation, &generated_text(case)?, key, limit)?;
            assert_eq!(
                actual.hashes,
                strings(&case["expected"])?,
                "fixture case {}",
                required_string(case, "id")?
            );
        }
        Ok(())
    }

    #[test]
    fn strict_bounds_and_key_validation_fail_closed() {
        let key = [0_u8; 32];
        assert_eq!(
            search(CloudVaultSearchOperation::Token, "ok", &[0_u8; 31], 1),
            Err(CloudVaultSearchError::InvalidKeyLength)
        );
        assert_eq!(
            search(
                CloudVaultSearchOperation::Token,
                "ok",
                &key,
                MAX_SEARCH_LIMIT + 1
            ),
            Err(CloudVaultSearchError::LimitTooLarge)
        );
        let oversized = "x".repeat(MAX_SEARCH_TEXT_BYTES + 1);
        assert_eq!(
            analyze(&oversized),
            Err(CloudVaultSearchError::TextTooLarge)
        );
        let too_many = (0..=MAX_SEARCH_TOKENS)
            .map(|index| format!("word{index}"))
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(
            analyze(&too_many),
            Err(CloudVaultSearchError::TooManyTokens)
        );
    }

    #[test]
    fn output_is_deterministic_bounded_and_key_isolated() -> Result<(), CloudVaultSearchError> {
        let primary = [7_u8; 32];
        let alternate = [8_u8; 32];
        let text = "Deploying deploys X ads API campaigns credentials";
        for operation in [
            CloudVaultSearchOperation::Token,
            CloudVaultSearchOperation::Index,
            CloudVaultSearchOperation::Query,
            CloudVaultSearchOperation::Semantic,
        ] {
            for limit in [1, 3, 24, 250] {
                let first = search(operation, text, &primary, limit)?;
                let second = search(operation, text, &primary, limit)?;
                assert_eq!(first, second);
                assert!(first.hashes.len() <= limit as usize);
                assert_eq!(
                    first.hashes.len(),
                    first.hashes.iter().collect::<HashSet<_>>().len()
                );
                assert_ne!(
                    first.hashes,
                    search(operation, text, &alternate, limit)?.hashes
                );
            }
        }
        Ok(())
    }

    #[test]
    fn generated_unicode_inputs_preserve_result_invariants() -> Result<(), CloudVaultSearchError> {
        let key = [0x5a_u8; 32];
        let alphabet = [
            'a', 'Z', '9', 'é', '東', '京', '𐐀', '𐐁', '-', '_', ' ', ',', '.', '\n', 'x',
        ];
        let mut state = 0x6a09_e667_f3bc_c909_u64;
        for case_index in 0..256 {
            let mut text = String::new();
            for _ in 0..(case_index % 257) {
                state = state
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1_442_695_040_888_963_407);
                text.push(alphabet[(state as usize) % alphabet.len()]);
            }
            let analysis = analyze(&text)?;
            assert!(analysis.normalized_tokens.len() <= MAX_SEARCH_TOKENS);
            assert!(analysis.exact_phrase_tokens.len() <= MAX_SEARCH_TOKENS);
            for operation in [
                CloudVaultSearchOperation::Token,
                CloudVaultSearchOperation::Index,
                CloudVaultSearchOperation::Query,
                CloudVaultSearchOperation::Semantic,
            ] {
                let result = search(operation, &text, &key, 31)?;
                assert!(result.hashes.len() <= 31);
                for hash in result.hashes {
                    assert_eq!(hash.len(), HASH_OUTPUT_LENGTH * 2);
                    assert!(hash.bytes().all(|byte| byte.is_ascii_hexdigit()));
                }
            }
        }
        Ok(())
    }
}
