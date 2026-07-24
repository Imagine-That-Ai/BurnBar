const MEDIA_FILE_PICKER_MAX_BYTES: usize = 4096;

/// Validate the path returned by the native chooser before handing it to the
/// daemon. The chooser is a UX boundary, not a trust boundary: a malicious
/// or stale shell must not turn the renderer into an arbitrary-path sender.
fn validate_media_file_picker_path(path: &Path) -> Result<&Path, String> {
    let path_text = path
        .to_str()
        .ok_or_else(|| "Media file path must be valid UTF-8.".to_string())?;
    if !path.is_absolute()
        || path_text.len() > MEDIA_FILE_PICKER_MAX_BYTES
        || path_text.chars().any(char::is_control)
        || path
            .components()
            .any(|component| matches!(component, std::path::Component::CurDir | std::path::Component::ParentDir))
    {
        return Err("Media file path is unsafe.".to_string());
    }
    let filename = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "Media file path must name a file.".to_string())?;
    if filename.is_empty() || filename == "." || filename == ".." || filename.len() > 255 {
        return Err("Media file path must name a file.".to_string());
    }
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| "Selected media file is unavailable.".to_string())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("Selected media path must be a regular file, not a symlink or directory.".to_string());
    }
    Ok(path)
}

/// Opens the platform-native file chooser for an outgoing Mercury transfer.
/// Cancellation is a normal `null` result; no daemon request is made.
#[tauri::command]
async fn pick_media_file(app: tauri::AppHandle) -> Result<Option<String>, String> {
    let selection = app
        .dialog()
        .file()
        .set_title("Choose file to send")
        .blocking_pick_file();
    let Some(selection) = selection else {
        return Ok(None);
    };
    let path = selection
        .into_path()
        .map_err(|_| "Native media file dialog returned an invalid path.".to_string())?;
    validate_media_file_picker_path(&path)?;
    Ok(Some(path.to_string_lossy().into_owned()))
}
