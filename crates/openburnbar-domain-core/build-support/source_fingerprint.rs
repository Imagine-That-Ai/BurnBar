use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env,
    error::Error,
    fs, io,
    path::{Component, Path, PathBuf},
};

const FINGERPRINT_ENV: &str = "OPENBURNBAR_DOMAIN_CORE_SOURCE_FINGERPRINT";
const FINGERPRINT_FIELD: &str = "sourceSha256";
const SOURCE_ROOTS_FIELD: &str = "sourceRoots";

pub fn emit_verified_source_fingerprint() -> Result<(), Box<dyn Error>> {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR")?);
    let crate_root = manifest_dir
        .parent()
        .ok_or_else(|| invalid_data("CARGO_MANIFEST_DIR has no openburnbar-domain-core parent"))?;
    let manifest_path = crate_root.join("union-abi-manifest.json");
    let helper_path = crate_root.join("build-support/source_fingerprint.rs");

    println!("cargo:rerun-if-changed={}", manifest_path.display());
    println!("cargo:rerun-if-changed={}", helper_path.display());

    let manifest: Value = serde_json::from_slice(&fs::read(&manifest_path)?).map_err(|error| {
        invalid_data(format!("cannot parse {}: {error}", manifest_path.display()))
    })?;
    if manifest.get("schemaVersion").and_then(Value::as_u64) != Some(1) {
        return Err(invalid_data("union ABI manifest schemaVersion must be exactly 1").into());
    }
    let expected = manifest
        .get(FINGERPRINT_FIELD)
        .and_then(Value::as_str)
        .ok_or_else(|| invalid_data("sourceSha256 must be a string"))?;
    if expected.len() != 64
        || !expected
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(
            invalid_data("sourceSha256 must be a 64-character lowercase SHA-256 digest").into(),
        );
    }

    let files = source_files(crate_root, &manifest)?;
    let actual = calculate_source_fingerprint(crate_root, &files)?;
    if actual != expected {
        return Err(invalid_data(format!(
            "domain-core source fingerprint drifted: manifest={expected} actual={actual}; review the source change and update the manifest"
        ))
        .into());
    }

    println!("cargo:rustc-env={FINGERPRINT_ENV}={actual}");
    Ok(())
}

fn source_files(
    crate_root: &Path,
    manifest: &Value,
) -> Result<BTreeMap<String, PathBuf>, Box<dyn Error>> {
    let roots = manifest
        .get(SOURCE_ROOTS_FIELD)
        .and_then(Value::as_array)
        .ok_or_else(|| invalid_data("sourceRoots must be a non-empty list"))?;
    if roots.is_empty() {
        return Err(invalid_data("sourceRoots must be a non-empty list").into());
    }

    let mut files = BTreeMap::new();
    for raw_root in roots {
        let relative_root = raw_root
            .as_str()
            .filter(|value| !value.is_empty())
            .ok_or_else(|| invalid_data("sourceRoots entries must be non-empty strings"))?;
        let candidate = crate_root.join(relative_root);
        println!("cargo:rerun-if-changed={}", candidate.display());
        if !candidate.exists() {
            return Err(invalid_data(format!("source root is missing: {relative_root}")).into());
        }
        if candidate.is_file() {
            insert_source_file(crate_root, candidate, &mut files)?;
        } else if candidate.is_dir() {
            collect_directory(crate_root, &candidate, &mut files)?;
        } else {
            return Err(invalid_data(format!(
                "source root is neither a file nor a directory: {relative_root}"
            ))
            .into());
        }
    }
    if files.is_empty() {
        return Err(invalid_data("sourceRoots resolved to no files").into());
    }
    Ok(files)
}

fn collect_directory(
    crate_root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, PathBuf>,
) -> Result<(), Box<dyn Error>> {
    let mut entries = fs::read_dir(directory)?.collect::<Result<Vec<_>, _>>()?;
    entries.sort_by_key(fs::DirEntry::file_name);
    for entry in entries {
        let path = entry.path();
        let relative = path.strip_prefix(crate_root).map_err(|_| {
            invalid_data(format!(
                "source path escaped crate root: {}",
                path.display()
            ))
        })?;
        if relative
            .components()
            .any(|component| component.as_os_str() == "target")
        {
            continue;
        }
        let file_type = entry.file_type()?;
        if file_type.is_file() || (file_type.is_symlink() && path.is_file()) {
            insert_source_file(crate_root, path, files)?;
        } else if file_type.is_dir() {
            collect_directory(crate_root, &path, files)?;
        }
    }
    Ok(())
}

fn insert_source_file(
    crate_root: &Path,
    path: PathBuf,
    files: &mut BTreeMap<String, PathBuf>,
) -> Result<(), Box<dyn Error>> {
    let relative = path.strip_prefix(crate_root).map_err(|_| {
        invalid_data(format!(
            "source path escaped crate root: {}",
            path.display()
        ))
    })?;
    let relative = posix_relative_path(relative)?;
    files.insert(relative, path);
    Ok(())
}

fn posix_relative_path(path: &Path) -> Result<String, Box<dyn Error>> {
    let mut parts = Vec::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_str().ok_or_else(|| {
                invalid_data(format!(
                    "source path is not valid UTF-8: {}",
                    path.display()
                ))
            })?),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(invalid_data(format!(
                    "source path is not relative to the crate root: {}",
                    path.display()
                ))
                .into());
            }
        }
    }
    if parts.is_empty() {
        return Err(invalid_data("source file has an empty relative path").into());
    }
    Ok(parts.join("/"))
}

fn calculate_source_fingerprint(
    crate_root: &Path,
    files: &BTreeMap<String, PathBuf>,
) -> Result<String, Box<dyn Error>> {
    let mut digest = Sha256::new();
    for (relative, path) in files {
        let relative_bytes = relative.as_bytes();
        let contents = fs::read(path)?;
        let relative_length = u32::try_from(relative_bytes.len())
            .map_err(|_| invalid_data(format!("source path is too long: {relative}")))?;
        let content_length = u64::try_from(contents.len())
            .map_err(|_| invalid_data(format!("source file is too large: {}", path.display())))?;

        digest.update(relative_length.to_be_bytes());
        digest.update(relative_bytes);
        digest.update(content_length.to_be_bytes());
        digest.update(contents);
        println!(
            "cargo:rerun-if-changed={}",
            crate_root.join(relative).display()
        );
    }
    Ok(format!("{:x}", digest.finalize()))
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}
