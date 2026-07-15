#[path = "../build-support/source_fingerprint.rs"]
mod source_fingerprint;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=src/lib.rs");
    source_fingerprint::emit_verified_source_fingerprint()?;
    println!("cargo:rerun-if-env-changed=OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT");
    let candidate_commit = std::env::var("OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT")
        .unwrap_or_else(|_| "0000000000000000000000000000000000000000".to_owned());
    if candidate_commit.len() != 40
        || !candidate_commit.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err("OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT must be a 40-character hexadecimal commit".into());
    }
    println!(
        "cargo:rustc-env=OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT={}",
        candidate_commit.to_ascii_lowercase()
    );
    let manifest_path = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?)
        .join("../union-abi-manifest.json");
    let manifest: serde_json::Value = serde_json::from_slice(&std::fs::read(manifest_path)?)?;
    let abi_version = manifest
        .get("abiVersion")
        .and_then(serde_json::Value::as_u64)
        .ok_or("union ABI manifest has no abiVersion")?;
    let source_sha256 = manifest
        .get("sourceSha256")
        .and_then(serde_json::Value::as_str)
        .ok_or("union ABI manifest has no sourceSha256")?;
    let core_version = std::env::var("CARGO_PKG_VERSION")?;
    let wire = format!(
        "openburnbar-domain-core-identity-v1|candidateCommit={candidate_commit}|coreVersion={core_version}|abiVersion={abi_version}|sourceSha256={source_sha256}"
    );
    let output = std::path::PathBuf::from(std::env::var("OUT_DIR")?)
        .join("openburnbar_domain_core_identity.c");
    std::fs::write(
        &output,
        format!(
            "#if defined(__APPLE__)\n__attribute__((used, retain, section(\"__TEXT,__obb_core_id\"), visibility(\"default\")))\n#else\n__attribute__((used, visibility(\"default\")))\n#endif\nconst unsigned char OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1[] = \"{wire}\";\n"
        ),
    )?;
    cc::Build::new()
        .cargo_metadata(false)
        .file(output)
        .compile("openburnbar_domain_core_identity");
    println!("cargo:rustc-link-search=native={}", std::env::var("OUT_DIR")?);
    println!("cargo:rustc-link-lib=static:+whole-archive=openburnbar_domain_core_identity");
    Ok(())
}
