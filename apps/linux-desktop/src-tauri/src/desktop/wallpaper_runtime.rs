const WALLPAPER_COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const WALLPAPER_STATE_FILE: &str = "desktop-wallpaper.json";

const WALLPAPER_THEMES: &[&str] = &[
    "macosDesktop",
    "midnight",
    "amoledBlack",
    "graphite",
    "warmEmber",
    "deepIndigo",
    "auroraTeal",
    "sunsetCrimson",
    "cyberpunkViolet",
    "forestMoss",
    "solarFlare",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "kebab-case")]
enum DesktopWallpaperBackend {
    Gnome,
    Kde,
    Xfce,
    Sway,
    Hyprland,
    Unsupported,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopWallpaperStatus {
    available: bool,
    backend: DesktopWallpaperBackend,
    state: String,
    theme: Option<String>,
    path: Option<String>,
    restore_available: bool,
    reason: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopWallpaperState {
    backend: DesktopWallpaperBackend,
    theme: String,
    path: String,
    #[serde(default)]
    previous: Option<DesktopWallpaperPreviousState>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopWallpaperPreviousState {
    backend: DesktopWallpaperBackend,
    path: String,
    #[serde(default)]
    dark_path: Option<String>,
}

fn wallpaper_theme_is_valid(theme: &str) -> bool {
    WALLPAPER_THEMES.contains(&theme)
}

fn desktop_backend_from_env_with<F>(desktop: Option<&str>, command_available: F) -> DesktopWallpaperBackend
where
    F: Fn(&str) -> bool,
{
    let desktop = desktop.unwrap_or_default().to_ascii_lowercase();
    if (desktop.contains("gnome")
        || desktop.contains("cinnamon")
        || desktop.contains("mate")
        || desktop.contains("unity"))
        && command_available("gsettings")
    {
        return DesktopWallpaperBackend::Gnome;
    }
    if (desktop.contains("kde") || desktop.contains("plasma"))
        && command_available("plasma-apply-wallpaperimage")
    {
        return DesktopWallpaperBackend::Kde;
    }
    if desktop.contains("xfce") && command_available("xfconf-query") {
        return DesktopWallpaperBackend::Xfce;
    }
    if desktop.contains("sway") && command_available("swaymsg") {
        return DesktopWallpaperBackend::Sway;
    }
    if desktop.contains("hyprland")
        && command_available("hyprctl")
        && command_available("hyprpaper")
    {
        return DesktopWallpaperBackend::Hyprland;
    }
    DesktopWallpaperBackend::Unsupported
}

/// Resolve only package-owned, absolute paths for desktop mutators. Never
/// execute an ambient `$PATH` command for a setting that changes the user's
/// desktop; a compromised PATH must result in an honest unavailable state.
fn trusted_wallpaper_executable(name: &str) -> Option<PathBuf> {
    let candidates: &[&str] = match name {
        "gsettings" => &["/usr/bin/gsettings", "/usr/local/bin/gsettings", "/bin/gsettings"],
        "plasma-apply-wallpaperimage" => &[
            "/usr/bin/plasma-apply-wallpaperimage",
            "/usr/local/bin/plasma-apply-wallpaperimage",
            "/bin/plasma-apply-wallpaperimage",
        ],
        "xfconf-query" => &["/usr/bin/xfconf-query", "/usr/local/bin/xfconf-query", "/bin/xfconf-query"],
        "swaymsg" => &["/usr/bin/swaymsg", "/usr/local/bin/swaymsg", "/bin/swaymsg"],
        "hyprctl" => &["/usr/bin/hyprctl", "/usr/local/bin/hyprctl", "/bin/hyprctl"],
        "hyprpaper" => &["/usr/bin/hyprpaper", "/usr/local/bin/hyprpaper", "/bin/hyprpaper"],
        _ => return None,
    };
    trusted_root_owned_executable(candidates)
}

fn command_available(name: &str) -> bool {
    trusted_wallpaper_executable(name).is_some()
}

fn detect_desktop_wallpaper_backend() -> DesktopWallpaperBackend {
    desktop_backend_from_env_with(
        std::env::var("XDG_CURRENT_DESKTOP").ok().as_deref(),
        command_available,
    )
}

fn wallpaper_status_from_state(
    backend: DesktopWallpaperBackend,
    state: Option<DesktopWallpaperState>,
    reason: Option<String>,
) -> DesktopWallpaperStatus {
    DesktopWallpaperStatus {
        available: backend != DesktopWallpaperBackend::Unsupported,
        backend,
        state: if reason.is_some() {
            "degraded".to_string()
        } else if state.is_some() {
            "applied".to_string()
        } else if backend == DesktopWallpaperBackend::Unsupported {
            "unsupported".to_string()
        } else {
            "ready".to_string()
        },
        theme: state.as_ref().map(|state| state.theme.clone()),
        path: state.as_ref().map(|state| state.path.clone()),
        restore_available: state
            .as_ref()
            .and_then(|state| state.previous.as_ref())
            .is_some(),
        reason,
    }
}

fn wallpaper_directory() -> Result<PathBuf, String> {
    let directory = linux_support_dir().join("wallpapers");
    fs::create_dir_all(&directory).map_err(|error| format!("wallpaper_directory_create:{error}"))?;
    let metadata = fs::symlink_metadata(&directory)
        .map_err(|error| format!("wallpaper_directory_stat:{error}"))?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("wallpaper_directory_unsafe".to_string());
    }
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("wallpaper_directory_permissions:{error}"))?;
    Ok(directory)
}

fn wallpaper_state_path(directory: &Path) -> PathBuf {
    directory.join(WALLPAPER_STATE_FILE)
}

fn read_wallpaper_state(directory: &Path) -> Option<DesktopWallpaperState> {
    let path = wallpaper_state_path(directory);
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn atomic_write(path: &Path, contents: &[u8], mode: u32) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "wallpaper_path_parent_missing".to_string())?;
    let suffix = format!(".tmp-{}", uuid::Uuid::new_v4().simple());
    let temporary = parent.join(format!(".{}{}", path.file_name().and_then(|name| name.to_str()).unwrap_or("wallpaper"), suffix));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temporary)
            .map_err(|error| format!("wallpaper_temp_create:{error}"))?;
        file.write_all(contents)
            .map_err(|error| format!("wallpaper_temp_write:{error}"))?;
        file.sync_all()
            .map_err(|error| format!("wallpaper_temp_sync:{error}"))?;
        fs::rename(&temporary, path).map_err(|error| format!("wallpaper_atomic_replace:{error}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn theme_svg(theme: &str) -> Result<String, String> {
    if !wallpaper_theme_is_valid(theme) {
        return Err("wallpaper_theme_invalid".to_string());
    }
    let (base, accent, highlight) = match theme {
        "macosDesktop" => ("#0d1117", "#2e74ed", "#fa5053"),
        "midnight" => ("#050816", "#0f2d64", "#1d4c91"),
        "amoledBlack" => ("#000000", "#000000", "#000000"),
        "graphite" => ("#101216", "#4d5360", "#1b202a"),
        "warmEmber" => ("#1d0d0a", "#783916", "#3c160e"),
        "deepIndigo" => ("#100e28", "#2e1e79", "#5d45ba"),
        "auroraTeal" => ("#06181a", "#0d5a64", "#2f9b9e"),
        "sunsetCrimson" => ("#19070d", "#6c1e34", "#b83e53"),
        "cyberpunkViolet" => ("#180b24", "#641f8f", "#b23cbb"),
        "forestMoss" => ("#08160d", "#184c2b", "#4b8f4d"),
        "solarFlare" => ("#191108", "#9a5c16", "#d2a437"),
        _ => return Err("wallpaper_theme_invalid".to_string()),
    };
    Ok(format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"2560\" height=\"1440\" viewBox=\"0 0 2560 1440\"><defs><radialGradient id=\"a\" cx=\"18%\" cy=\"12%\" r=\"80%\"><stop offset=\"0\" stop-color=\"{accent}\"/><stop offset=\"1\" stop-color=\"{base}\"/></radialGradient><radialGradient id=\"b\" cx=\"88%\" cy=\"82%\" r=\"75%\"><stop offset=\"0\" stop-color=\"{highlight}\" stop-opacity=\".9\"/><stop offset=\"1\" stop-color=\"{base}\" stop-opacity=\"0\"/></radialGradient></defs><rect width=\"2560\" height=\"1440\" fill=\"{base}\"/><rect width=\"2560\" height=\"1440\" fill=\"url(#a)\"/><rect width=\"2560\" height=\"1440\" fill=\"url(#b)\"/></svg>"
    ))
}

fn file_uri(path: &Path) -> Result<String, String> {
    let path = path
        .to_str()
        .ok_or_else(|| "wallpaper_path_invalid".to_string())?;
    let mut uri = String::from("file://");
    for byte in path.as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            uri.push(*byte as char);
        } else {
            uri.push_str(&format!("%{byte:02X}"));
        }
    }
    Ok(uri)
}

fn bounded_output(mut command: Command) -> Result<(), String> {
    let mut child = command
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("wallpaper_command_spawn:{error}"))?;
    let deadline = Instant::now() + WALLPAPER_COMMAND_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => {
                let output = child
                    .wait_with_output()
                    .map_err(|error| format!("wallpaper_command_wait:{error}"))?;
                let detail = String::from_utf8_lossy(&output.stderr)
                    .chars()
                    .filter(|character| !character.is_control())
                    .take(240)
                    .collect::<String>();
                return Err(if detail.is_empty() {
                    format!("wallpaper_command_failed:{status}")
                } else {
                    format!("wallpaper_command_failed:{detail}")
                });
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("wallpaper_command_timeout".to_string());
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("wallpaper_command_status:{error}"));
            }
        }
    }
}

fn bounded_query_output(mut command: Command) -> Result<String, String> {
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("wallpaper_query_spawn:{error}"))?;
    let deadline = Instant::now() + WALLPAPER_COMMAND_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                let output = child
                    .wait_with_output()
                    .map_err(|error| format!("wallpaper_query_wait:{error}"))?;
                if output.stdout.len() > 16 * 1024 {
                    return Err("wallpaper_query_output_too_large".to_string());
                }
                return String::from_utf8(output.stdout)
                    .map_err(|_| "wallpaper_query_output_invalid_utf8".to_string());
            }
            Ok(Some(_)) => return Err("wallpaper_query_failed".to_string()),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("wallpaper_query_timeout".to_string());
            }
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("wallpaper_query_status:{error}"));
            }
        }
    }
}

fn percent_decode_file_uri(uri: &str) -> Option<PathBuf> {
    let encoded = uri.strip_prefix("file://")?;
    if !encoded.starts_with('/') {
        return None;
    }
    let bytes = encoded.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return None;
            }
            let high = (bytes[index + 1] as char).to_digit(16)? as u8;
            let low = (bytes[index + 2] as char).to_digit(16)? as u8;
            decoded.push((high << 4) | low);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    let path = PathBuf::from(String::from_utf8(decoded).ok()?);
    path.is_absolute().then_some(path)
}

fn restore_path(raw: &str) -> Option<PathBuf> {
    let path = if raw.starts_with("file://") {
        percent_decode_file_uri(raw)?
    } else {
        PathBuf::from(raw)
    };
    if !path.is_absolute() {
        return None;
    }
    let metadata = fs::symlink_metadata(&path).ok()?;
    (metadata.is_file() && !metadata.file_type().is_symlink()).then_some(path)
}

fn gsettings_wallpaper_path(output: &str) -> Option<PathBuf> {
    let value = output.trim().trim_matches(|character| character == '\'' || character == '"');
    percent_decode_file_uri(value)
}

fn query_wallpaper_path(backend: DesktopWallpaperBackend) -> Option<DesktopWallpaperPreviousState> {
    match backend {
        DesktopWallpaperBackend::Gnome => {
            let executable = trusted_wallpaper_executable("gsettings")?;
            let mut light = Command::new(&executable);
            light.args(["get", "org.gnome.desktop.background", "picture-uri"]);
            let path = gsettings_wallpaper_path(&bounded_query_output(light).ok()?)?;
            let mut dark = Command::new(executable);
            dark.args(["get", "org.gnome.desktop.background", "picture-uri-dark"]);
            let dark_path = bounded_query_output(dark)
                .ok()
                .and_then(|output| gsettings_wallpaper_path(&output))
                .filter(|candidate| candidate != &path)
                .map(|candidate| candidate.to_string_lossy().into_owned());
            Some(DesktopWallpaperPreviousState {
                backend,
                path: path.to_string_lossy().into_owned(),
                dark_path,
            })
        }
        DesktopWallpaperBackend::Xfce => {
            let executable = trusted_wallpaper_executable("xfconf-query")?;
            let mut command = Command::new(executable);
            command.args([
                "-c",
                "xfce4-desktop",
                "-p",
                "/backdrop/screen0/monitor0/image-path",
            ]);
            let path = restore_path(bounded_query_output(command).ok()?.trim())?;
            Some(DesktopWallpaperPreviousState {
                backend,
                path: path.to_string_lossy().into_owned(),
                dark_path: None,
            })
        }
        DesktopWallpaperBackend::Hyprland => {
            let executable = trusted_wallpaper_executable("hyprctl")?;
            let mut command = Command::new(executable);
            command.args(["hyprpaper", "listactive", "-j"]);
            let value: serde_json::Value = serde_json::from_str(&bounded_query_output(command).ok()?).ok()?;
            let path = value.as_array()?.iter().find_map(|entry| {
                entry
                    .get("wallpaper")
                    .and_then(serde_json::Value::as_str)
                    .and_then(restore_path)
            })?;
            Some(DesktopWallpaperPreviousState {
                backend,
                path: path.to_string_lossy().into_owned(),
                dark_path: None,
            })
        }
        DesktopWallpaperBackend::Kde
        | DesktopWallpaperBackend::Sway
        | DesktopWallpaperBackend::Unsupported => None,
    }
}

fn apply_previous_wallpaper(previous: &DesktopWallpaperPreviousState) -> Result<(), String> {
    let path = restore_path(&previous.path).ok_or_else(|| "wallpaper_previous_path_unavailable".to_string())?;
    match previous.backend {
        DesktopWallpaperBackend::Gnome => {
            let uri = file_uri(&path)?;
            let executable = trusted_wallpaper_executable("gsettings")
                .ok_or_else(|| "wallpaper_command_unavailable:gsettings".to_string())?;
            let mut light = Command::new(&executable);
            light.args(["set", "org.gnome.desktop.background", "picture-uri", &uri]);
            bounded_output(light)?;
            let dark_path = previous
                .dark_path
                .as_deref()
                .and_then(restore_path)
                .unwrap_or_else(|| path.clone());
            let dark_uri = file_uri(&dark_path)?;
            let mut dark = Command::new(executable);
            dark.args(["set", "org.gnome.desktop.background", "picture-uri-dark", &dark_uri]);
            let _ = bounded_output(dark);
            Ok(())
        }
        DesktopWallpaperBackend::Xfce | DesktopWallpaperBackend::Hyprland => {
            apply_wallpaper_with_backend(previous.backend, &path)
        }
        DesktopWallpaperBackend::Kde
        | DesktopWallpaperBackend::Sway
        | DesktopWallpaperBackend::Unsupported => {
            Err("wallpaper_previous_restore_unsupported".to_string())
        }
    }
}

fn apply_wallpaper_with_backend(backend: DesktopWallpaperBackend, path: &Path) -> Result<(), String> {
    let uri = file_uri(path)?;
    match backend {
        DesktopWallpaperBackend::Gnome => {
            let mut light = Command::new(
                trusted_wallpaper_executable("gsettings")
                    .ok_or_else(|| "wallpaper_command_unavailable:gsettings".to_string())?,
            );
            light.args([
                "set",
                "org.gnome.desktop.background",
                "picture-uri",
                &uri,
            ]);
            bounded_output(light)?;
            // GNOME 42+ keeps separate dark/light URIs. Older schemas reject
            // this key; the light URI above is still a successful application.
            let mut dark = Command::new(
                trusted_wallpaper_executable("gsettings")
                    .ok_or_else(|| "wallpaper_command_unavailable:gsettings".to_string())?,
            );
            dark.args([
                "set",
                "org.gnome.desktop.background",
                "picture-uri-dark",
                &uri,
            ]);
            let _ = bounded_output(dark);
            Ok(())
        }
        DesktopWallpaperBackend::Kde => {
            let mut command = Command::new(trusted_wallpaper_executable(
                "plasma-apply-wallpaperimage",
            )
            .ok_or_else(|| {
                "wallpaper_command_unavailable:plasma-apply-wallpaperimage".to_string()
            })?);
            command.arg(path);
            bounded_output(command)
        }
        DesktopWallpaperBackend::Xfce => {
            let mut command = Command::new(
                trusted_wallpaper_executable("xfconf-query")
                    .ok_or_else(|| "wallpaper_command_unavailable:xfconf-query".to_string())?,
            );
            command.args([
                "-c",
                "xfce4-desktop",
                "-p",
                "/backdrop/screen0/monitor0/image-path",
                "-s",
                path.to_str().ok_or_else(|| "wallpaper_path_invalid".to_string())?,
            ]);
            bounded_output(command)
        }
        DesktopWallpaperBackend::Sway => {
            let mut command = Command::new(
                trusted_wallpaper_executable("swaymsg")
                    .ok_or_else(|| "wallpaper_command_unavailable:swaymsg".to_string())?,
            );
            command.args([
                "output",
                "*",
                "bg",
                path.to_str().ok_or_else(|| "wallpaper_path_invalid".to_string())?,
                "fill",
            ]);
            bounded_output(command)
        }
        DesktopWallpaperBackend::Hyprland => {
            let hyprctl = trusted_wallpaper_executable("hyprctl")
                .ok_or_else(|| "wallpaper_command_unavailable:hyprctl".to_string())?;
            // Hyprpaper owns the image cache. Preload before switching so a
            // failed decode never replaces the currently visible wallpaper.
            let mut preload = Command::new(&hyprctl);
            preload.args([
                "hyprpaper",
                "preload",
                path.to_str().ok_or_else(|| "wallpaper_path_invalid".to_string())?,
            ]);
            bounded_output(preload)?;
            let mut wallpaper = Command::new(hyprctl);
            let assignment = format!(
                ",{}",
                path.to_str().ok_or_else(|| "wallpaper_path_invalid".to_string())?
            );
            wallpaper.args(["hyprpaper", "wallpaper", &assignment]);
            bounded_output(wallpaper)
        }
        DesktopWallpaperBackend::Unsupported => Err("wallpaper_backend_unsupported".to_string()),
    }
}

fn desktop_wallpaper_status_impl() -> Result<DesktopWallpaperStatus, String> {
    let backend = detect_desktop_wallpaper_backend();
    let directory = wallpaper_directory()?;
    Ok(wallpaper_status_from_state(backend, read_wallpaper_state(&directory), None))
}

#[tauri::command]
fn desktop_wallpaper_status() -> Result<DesktopWallpaperStatus, String> {
    desktop_wallpaper_status_impl()
}

#[tauri::command]
fn desktop_wallpaper_apply(theme: String) -> Result<DesktopWallpaperStatus, String> {
    let svg = theme_svg(&theme)?;
    let backend = detect_desktop_wallpaper_backend();
    if backend == DesktopWallpaperBackend::Unsupported {
        return Ok(wallpaper_status_from_state(
            backend,
            None,
            Some("wallpaper_backend_unsupported".to_string()),
        ));
    }
    let directory = wallpaper_directory()?;
    let path = directory.join(format!("{theme}.svg"));
    if fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err("wallpaper_path_unsafe".to_string());
    }
    let previous = read_wallpaper_state(&directory)
        .and_then(|state| state.previous)
        .or_else(|| query_wallpaper_path(backend));
    atomic_write(&path, svg.as_bytes(), 0o600)?;
    if let Err(error) = apply_wallpaper_with_backend(backend, &path) {
        return Ok(wallpaper_status_from_state(backend, None, Some(error)));
    }
    let state = DesktopWallpaperState {
        backend,
        theme,
        path: path.to_string_lossy().into_owned(),
        previous,
    };
    let state_path = wallpaper_state_path(&directory);
    atomic_write(
        &state_path,
        &serde_json::to_vec(&state).map_err(|error| format!("wallpaper_state_encode:{error}"))?,
        0o600,
    )?;
    Ok(wallpaper_status_from_state(backend, Some(state), None))
}

#[tauri::command]
fn desktop_wallpaper_restore() -> Result<DesktopWallpaperStatus, String> {
    let backend = detect_desktop_wallpaper_backend();
    let directory = wallpaper_directory()?;
    let state = match read_wallpaper_state(&directory) {
        Some(state) => state,
        None => {
            return Ok(wallpaper_status_from_state(
                backend,
                None,
                Some("wallpaper_previous_unavailable".to_string()),
            ));
        }
    };
    let previous = match state.previous.as_ref() {
        Some(previous) => previous,
        None => {
            return Ok(wallpaper_status_from_state(
                backend,
                Some(state),
                Some("wallpaper_previous_unavailable".to_string()),
            ));
        }
    };
    if previous.backend != backend {
        return Ok(wallpaper_status_from_state(
            backend,
            Some(state),
            Some("wallpaper_backend_changed".to_string()),
        ));
    }
    if let Err(error) = apply_previous_wallpaper(previous) {
        return Ok(wallpaper_status_from_state(backend, Some(state), Some(error)));
    }
    fs::remove_file(wallpaper_state_path(&directory))
        .map_err(|error| format!("wallpaper_state_remove:{error}"))?;
    Ok(DesktopWallpaperStatus {
        available: backend != DesktopWallpaperBackend::Unsupported,
        backend,
        state: "restored".to_string(),
        theme: None,
        path: Some(previous.path.clone()),
        restore_available: false,
        reason: None,
    })
}
