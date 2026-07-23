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
    reason: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct DesktopWallpaperState {
    backend: DesktopWallpaperBackend,
    theme: String,
    path: String,
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
    DesktopWallpaperBackend::Unsupported
}

fn command_available(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|directory| {
        let candidate = directory.join(name);
        fs::metadata(candidate).is_ok_and(|metadata| {
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
        })
    })
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

fn apply_wallpaper_with_backend(backend: DesktopWallpaperBackend, path: &Path) -> Result<(), String> {
    let uri = file_uri(path)?;
    match backend {
        DesktopWallpaperBackend::Gnome => {
            let mut light = Command::new("gsettings");
            light.args([
                "set",
                "org.gnome.desktop.background",
                "picture-uri",
                &uri,
            ]);
            bounded_output(light)?;
            // GNOME 42+ keeps separate dark/light URIs. Older schemas reject
            // this key; the light URI above is still a successful application.
            let mut dark = Command::new("gsettings");
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
            let mut command = Command::new("plasma-apply-wallpaperimage");
            command.arg(path);
            bounded_output(command)
        }
        DesktopWallpaperBackend::Xfce => {
            let mut command = Command::new("xfconf-query");
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
    atomic_write(&path, svg.as_bytes(), 0o600)?;
    if let Err(error) = apply_wallpaper_with_backend(backend, &path) {
        return Ok(wallpaper_status_from_state(backend, None, Some(error)));
    }
    let state = DesktopWallpaperState {
        backend,
        theme,
        path: path.to_string_lossy().into_owned(),
    };
    let state_path = wallpaper_state_path(&directory);
    atomic_write(
        &state_path,
        &serde_json::to_vec(&state).map_err(|error| format!("wallpaper_state_encode:{error}"))?,
        0o600,
    )?;
    Ok(wallpaper_status_from_state(backend, Some(state), None))
}
