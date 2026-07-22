// BEGIN OPENBURNBAR SAFE QUOTA FFI SHIM
// This source is injected by scripts/build-domain-core-xcframework.sh. Keep it
// in this file so regenerating UniFFI bindings deterministically preserves the
// recoverable shadow-mode entry points.
public enum SafeQuotaFFIError: Error, Sendable {
    case contractVersionMismatch
    case apiChecksumMismatch
}

private func safeQuotaRustCall<T>(
    _ callback: (UnsafeMutablePointer<RustCallStatus>) -> T
) throws -> T {
    switch initializationResult {
    case .ok:
        break
    case .contractVersionMismatch:
        throw SafeQuotaFFIError.contractVersionMismatch
    case .apiChecksumMismatch:
        throw SafeQuotaFFIError.apiChecksumMismatch
    }

    var callStatus = RustCallStatus.init()
    let returnedValue = callback(&callStatus)
    let neverThrow: ((RustBuffer) throws -> Never)? = nil
    try uniffiCheckCallStatus(callStatus: callStatus, errorHandler: neverThrow)
    return returnedValue
}

public enum SafeQuotaFFI {
    public static func domainCoreAbiVersion() throws -> UInt32 {
        try FfiConverterUInt32.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version($0)
        })
    }

    public static func domainCoreVersion() throws -> String {
        try FfiConverterString.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_domain_core_version($0)
        })
    }

    public static func parseClaudeStatuslineQuota(payload: Data) throws -> QuotaParseResult {
        try FfiConverterTypeQuotaParseResult.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_parse_claude_statusline_quota(
                FfiConverterData.lower(payload),
                $0
            )
        })
    }

    public static func parseCodexUsageQuota(payload: Data, nowUnix: Int64) throws -> QuotaParseResult {
        try FfiConverterTypeQuotaParseResult.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_parse_codex_usage_quota(
                FfiConverterData.lower(payload),
                FfiConverterInt64.lower(nowUnix),
                $0
            )
        })
    }

    public static func parseCursorUsageQuota(payload: Data, userEmail: String?) throws -> QuotaParseResult {
        try FfiConverterTypeQuotaParseResult.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_parse_cursor_usage_quota(
                FfiConverterData.lower(payload),
                FfiConverterOptionString.lower(userEmail),
                $0
            )
        })
    }

    public static func parseAnthropicRateLimitHeaders(
        payload: Data,
        nowUnix: Int64,
        shape: AnthropicCredentialShape
    ) throws -> QuotaParseResult {
        try FfiConverterTypeQuotaParseResult.lift(try safeQuotaRustCall {
            uniffi_openburnbar_domain_ffi_fn_func_parse_anthropic_rate_limit_headers(
                FfiConverterData.lower(payload),
                FfiConverterInt64.lower(nowUnix),
                FfiConverterTypeAnthropicCredentialShape.lower(shape),
                $0
            )
        })
    }
}
// END OPENBURNBAR SAFE QUOTA FFI SHIM
