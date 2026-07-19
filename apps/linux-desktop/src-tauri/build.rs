use std::{env, fs, path::Path};

fn main() {
    tauri_build::build();
    emit_frontend_asset_dependencies();
}

/// Tauri's generated context embeds compressed frontend files. Watching only
/// the dist directory can miss in-place edits to an existing asset, leaving
/// Cargo with a binary that serves an older embedded page. Emit one dependency
/// for every file so a release rebuild always refreshes the embedded surface.
fn emit_frontend_asset_dependencies() {
    let manifest_dir = env::var_os("CARGO_MANIFEST_DIR")
        .map(std::path::PathBuf::from)
        .expect("CARGO_MANIFEST_DIR is required for the Tauri build");
    let dist = manifest_dir.join("../dist");
    emit_file_dependencies(&dist);
}

fn emit_file_dependencies(path: &Path) {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => panic!(
            "failed to read frontend asset directory {}: {error}",
            path.display()
        ),
    };

    for entry in entries {
        let entry = entry.unwrap_or_else(|error| {
            panic!(
                "failed to read frontend asset entry in {}: {error}",
                path.display()
            )
        });
        let entry_path = entry.path();
        if entry
            .file_type()
            .unwrap_or_else(|error| {
                panic!(
                    "failed to inspect frontend asset {}: {error}",
                    entry_path.display()
                )
            })
            .is_dir()
        {
            emit_file_dependencies(&entry_path);
        } else {
            println!("cargo:rerun-if-changed={}", entry_path.display());
        }
    }
}
