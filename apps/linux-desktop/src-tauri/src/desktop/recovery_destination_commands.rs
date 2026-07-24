#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum RecoveryBundlePickerMode {
    Export,
    Import,
}

fn validate_recovery_bundle_picker_path(path: &Path) -> Result<&Path, String> {
    validate_safe_absolute_path(path, "recovery_bundle")?;
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Recovery bundle path must name a file.".to_string())?;
    let stem = filename.strip_suffix(".obb").unwrap_or_default();
    if filename.is_empty()
        || filename.len() > 128
        || filename.starts_with('.')
        || stem.is_empty()
        || stem
            .chars()
            .any(|character| !character.is_ascii_alphanumeric() && !matches!(character, '.' | '_' | '-'))
    {
        return Err("Recovery bundle path has an unsupported filename.".to_string());
    }
    if fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("Recovery bundle path must not be a symlink.".to_string());
    }
    Ok(path)
}

/// Opens a native file dialog for the daemon-owned encrypted recovery bundle.
/// Export uses a save dialog; import only permits selecting an existing `.obb`
/// file. Dismissing either dialog is a normal `null` result.
#[tauri::command]
async fn pick_recovery_bundle_destination(
    app: AppHandle,
    mode: RecoveryBundlePickerMode,
) -> Result<Option<String>, String> {
    let builder = app
        .dialog()
        .file()
        .set_title(match mode {
            RecoveryBundlePickerMode::Export => "Save encrypted recovery bundle",
            RecoveryBundlePickerMode::Import => "Choose encrypted recovery bundle",
        })
        .add_filter("OpenBurnBar recovery bundle", &["obb"]);
    let destination = match mode {
        RecoveryBundlePickerMode::Export => builder
            .set_file_name("openburnbar-recovery.obb")
            .set_can_create_directories(false)
            .blocking_save_file(),
        RecoveryBundlePickerMode::Import => builder.blocking_pick_file(),
    };
    let Some(destination) = destination else {
        return Ok(None);
    };
    let path = destination
        .into_path()
        .map_err(|_| "Native recovery dialog returned an invalid path.".to_string())?;
    validate_recovery_bundle_picker_path(&path)?;
    Ok(Some(path.to_string_lossy().into_owned()))
}
