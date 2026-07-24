#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
enum ExportDestinationKind {
    LinuxPrivacy,
    AccountCloud,
}

struct ExportDestinationDialogSpec {
    title: &'static str,
    file_name: &'static str,
    filter_name: &'static str,
    extension: &'static str,
}

fn export_destination_dialog_spec(kind: ExportDestinationKind) -> ExportDestinationDialogSpec {
    match kind {
        ExportDestinationKind::LinuxPrivacy => ExportDestinationDialogSpec {
            title: "Save encrypted local privacy export",
            file_name: "openburnbar-privacy-export.obb",
            filter_name: "OpenBurnBar privacy export",
            extension: "obb",
        },
        ExportDestinationKind::AccountCloud => ExportDestinationDialogSpec {
            title: "Save account data export",
            file_name: "openburnbar-account-export.json",
            filter_name: "OpenBurnBar account export",
            extension: "json",
        },
    }
}

fn validate_export_destination(
    path: &Path,
    kind: ExportDestinationKind,
) -> Result<&Path, String> {
    validate_safe_absolute_path(path, "export_destination")?;
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Native export destination must name a file.".to_string())?;
    let spec = export_destination_dialog_spec(kind);
    let suffix = format!(".{}", spec.extension);
    let stem = filename.strip_suffix(&suffix).unwrap_or_default();
    if filename.is_empty()
        || filename.len() > 128
        || filename.starts_with('.')
        || stem.is_empty()
        || stem
            .chars()
            .any(|character| !character.is_ascii_alphanumeric() && !matches!(character, '.' | '_' | '-'))
    {
        return Err("Native export destination has an unsupported filename.".to_string());
    }
    if fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("Native export destination must not be a symlink.".to_string());
    }
    Ok(path)
}

/// Opens a native save dialog for one of the two export workflows. The
/// renderer never supplies a path to the dialog and cancellation is a normal
/// result, so dismissing the dialog cannot start an export or surface an error.
#[tauri::command]
async fn pick_export_destination(
    app: AppHandle,
    kind: ExportDestinationKind,
) -> Result<Option<String>, String> {
    let spec = export_destination_dialog_spec(kind);
    let destination = app
        .dialog()
        .file()
        .set_title(spec.title)
        .set_file_name(spec.file_name)
        .add_filter(spec.filter_name, &[spec.extension])
        .set_can_create_directories(false)
        .blocking_save_file();
    let Some(destination) = destination else {
        return Ok(None);
    };
    let path = destination
        .into_path()
        .map_err(|_| "Native export dialog returned an invalid path.".to_string())?;
    validate_export_destination(&path, kind)?;
    Ok(Some(path.to_string_lossy().into_owned()))
}
