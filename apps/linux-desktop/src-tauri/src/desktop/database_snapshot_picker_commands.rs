#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum DatabaseSnapshotPickerMode {
    Export,
    Import,
}

fn validate_database_snapshot_picker_path(path: &Path) -> Result<&Path, String> {
    validate_safe_absolute_path(path, "database_snapshot")?;
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Database snapshot path must name a file.".to_string())?;
    let stem = filename.strip_suffix(".snapshot").unwrap_or_default();
    if filename.is_empty()
        || filename.len() > 128
        || filename.starts_with('.')
        || stem.is_empty()
        || stem.chars().any(|character| {
            !character.is_ascii_alphanumeric() && !matches!(character, '.' | '_' | '-')
        })
    {
        return Err("Database snapshot path has an unsupported filename.".to_string());
    }
    if fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("Database snapshot path must not be a symlink.".to_string());
    }
    Ok(path)
}

/// Opens a native save/open dialog for encrypted SQLCipher snapshots. The
/// renderer never supplies a path to the dialog; cancelling either flow is a
/// normal null result and does not invoke the daemon.
#[tauri::command]
async fn pick_database_snapshot_path(
    app: AppHandle,
    mode: DatabaseSnapshotPickerMode,
) -> Result<Option<String>, String> {
    let builder = app
        .dialog()
        .file()
        .set_title(match mode {
            DatabaseSnapshotPickerMode::Export => "Save encrypted database snapshot",
            DatabaseSnapshotPickerMode::Import => "Choose encrypted database snapshot",
        })
        .add_filter("OpenBurnBar encrypted snapshot", &["snapshot"]);
    let destination = match mode {
        DatabaseSnapshotPickerMode::Export => builder
            .set_file_name("openburnbar-code.snapshot")
            .set_can_create_directories(false)
            .blocking_save_file(),
        DatabaseSnapshotPickerMode::Import => builder.blocking_pick_file(),
    };
    let Some(destination) = destination else {
        return Ok(None);
    };
    let path = destination
        .into_path()
        .map_err(|_| "Native database snapshot dialog returned an invalid path.".to_string())?;
    validate_database_snapshot_picker_path(&path)?;
    Ok(Some(path.to_string_lossy().into_owned()))
}
