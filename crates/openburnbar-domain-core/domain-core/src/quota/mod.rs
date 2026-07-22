mod anthropic_headers;
mod claude_statusline;
mod codex_usage;
mod cursor_usage;
mod types;

pub(crate) const MAX_QUOTA_PAYLOAD_BYTES: usize = 1024 * 1024;

pub use anthropic_headers::{parse_anthropic_rate_limit_headers, AnthropicCredentialShape};
pub use claude_statusline::parse_claude_statusline_quota;
pub use codex_usage::parse_codex_usage_quota;
pub use cursor_usage::parse_cursor_usage_quota;
pub use types::{
    QuotaBucket, QuotaConfidence, QuotaParseResult, QuotaParseStatus, QuotaSnapshot,
    QuotaSourceKind, QuotaUnit, QuotaWindowKind,
};

#[cfg(test)]
mod property_tests {
    use super::*;

    fn assert_finite(result: &QuotaParseResult) {
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
                assert!(value.is_finite());
            }
        }
    }

    #[test]
    fn arbitrary_payloads_never_emit_nonfinite_values() {
        let mut state = 0x9e37_79b9_u32;
        for length in 0..512 {
            let mut payload = vec![0_u8; length];
            for byte in &mut payload {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *byte = state.to_le_bytes()[0];
            }
            assert_finite(&parse_claude_statusline_quota(&payload));
            assert_finite(&parse_codex_usage_quota(&payload, i64::MAX));
            assert_finite(&parse_cursor_usage_quota(&payload, None));
            assert_finite(&parse_anthropic_rate_limit_headers(
                &payload,
                i64::MIN,
                AnthropicCredentialShape::OauthBearer,
            ));
        }
    }

    #[test]
    fn every_parser_rejects_oversized_payloads_before_json_decode() {
        let payload = vec![b' '; MAX_QUOTA_PAYLOAD_BYTES + 1];
        assert_eq!(
            parse_claude_statusline_quota(&payload).status,
            QuotaParseStatus::Malformed
        );
        assert_eq!(
            parse_codex_usage_quota(&payload, 0).status,
            QuotaParseStatus::Malformed
        );
        assert_eq!(
            parse_cursor_usage_quota(&payload, None).status,
            QuotaParseStatus::Malformed
        );
        assert_eq!(
            parse_anthropic_rate_limit_headers(&payload, 0, AnthropicCredentialShape::OauthBearer,)
                .status,
            QuotaParseStatus::Malformed
        );
    }
}
