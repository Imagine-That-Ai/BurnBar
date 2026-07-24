#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GatewayProxyMessage {
    role: String,
    content: String,
    #[serde(default)]
    attachments: Vec<GatewayAttachmentReference>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct GatewayAttachmentReference {
    attachment_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GatewayProxyRequest {
    request_id: String,
    model: String,
    messages: Vec<GatewayProxyMessage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentUploadRequest {
    file_name: String,
    mime_type: String,
    content_base64: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentUploadResult {
    attachment_id: String,
    file_name: String,
    mime_type: String,
    byte_size: usize,
    sha256: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct GatewayAttachmentCapability {
    mime_type: String,
    state: String,
    reason: String,
    max_bytes: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct GatewayModelCatalogResponse {
    #[serde(default)]
    data: Vec<GatewayModelCatalogEntry>,
}

#[derive(Debug, Deserialize)]
struct GatewayModelCatalogEntry {
    id: String,
    #[serde(
        default,
        alias = "baseModelID",
        alias = "baseModelId",
        alias = "base_model_id"
    )]
    base_model_id: Option<String>,
    #[serde(default, alias = "modelCapabilities", alias = "model_capabilities")]
    model_capabilities: Option<GatewayModelIOCapabilities>,
}

#[derive(Debug, Deserialize)]
struct GatewayModelIOCapabilities {
    #[serde(default, alias = "inputModalities", alias = "input_modalities")]
    input_modalities: Vec<String>,
    #[serde(
        default,
        alias = "acceptedInputMimeTypes",
        alias = "accepted_input_mime_types"
    )]
    accepted_input_mime_types: Vec<String>,
    #[serde(default, alias = "imageMaxBytes", alias = "image_max_bytes")]
    image_max_bytes: Option<usize>,
}

#[derive(Debug, Clone)]
struct StoredChatAttachment {
    path: PathBuf,
    file_name: String,
    mime_type: String,
    byte_size: usize,
    sha256: String,
}

static CHAT_ATTACHMENTS: OnceLock<Mutex<HashMap<String, StoredChatAttachment>>> = OnceLock::new();

fn chat_attachments() -> &'static Mutex<HashMap<String, StoredChatAttachment>> {
    CHAT_ATTACHMENTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn chat_attachment_root() -> PathBuf {
    linux_support_dir().join("chat-attachments")
}

fn is_allowed_chat_attachment_mime(mime_type: &str) -> bool {
    matches!(
        mime_type,
        "text/plain"
            | "text/markdown"
            | "text/csv"
            | "application/json"
            | "application/pdf"
            | "image/png"
            | "image/jpeg"
            | "image/webp"
    )
}

fn is_gateway_text_attachment_mime(mime_type: &str) -> bool {
    matches!(
        mime_type,
        "text/plain" | "text/markdown" | "text/csv" | "application/json"
    )
}

fn is_gateway_native_attachment_mime(mime_type: &str) -> bool {
    matches!(
        mime_type,
        "application/pdf" | "image/png" | "image/jpeg" | "image/webp"
    )
}

fn inferred_chat_attachment_mime(file_name: &str) -> Option<&'static str> {
    match Path::new(file_name)
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "txt" => Some("text/plain"),
        "md" | "markdown" => Some("text/markdown"),
        "csv" => Some("text/csv"),
        "json" => Some("application/json"),
        "pdf" => Some("application/pdf"),
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "webp" => Some("image/webp"),
        _ => None,
    }
}

fn validate_chat_attachment_file_name(file_name: &str) -> Result<String, String> {
    let trimmed = file_name.trim();
    if trimmed.is_empty() || trimmed.as_bytes().len() > CHAT_ATTACHMENT_MAX_NAME_BYTES {
        return Err("chat_attachment_invalid_file_name".into());
    }
    if trimmed == "."
        || trimmed == ".."
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.chars().any(|character| character.is_control())
    {
        return Err("chat_attachment_invalid_file_name".into());
    }
    Ok(trimmed.to_string())
}

fn canonical_chat_attachment_mime(file_name: &str, mime_type: &str) -> Result<String, String> {
    let normalized = mime_type.trim().to_ascii_lowercase();
    let inferred = inferred_chat_attachment_mime(file_name);
    let canonical = if normalized.is_empty() || normalized == "application/octet-stream" {
        inferred.unwrap_or("").to_string()
    } else if is_allowed_chat_attachment_mime(&normalized) {
        normalized
    } else {
        return Err("chat_attachment_unsupported_type".into());
    };
    if !is_allowed_chat_attachment_mime(&canonical) {
        return Err("chat_attachment_unsupported_type".into());
    }
    if let Some(inferred) = inferred {
        if inferred != canonical {
            return Err("chat_attachment_type_mismatch".into());
        }
    }
    Ok(canonical)
}

fn validate_private_attachment_path(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|_| "chat_attachment_missing".to_string())?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err("chat_attachment_ownership_invalid".into());
    }
    if metadata.mode() & 0o077 != 0 {
        return Err("chat_attachment_permissions_invalid".into());
    }
    Ok(())
}

fn validate_private_attachment_directory(path: &Path) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path)
        .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err("chat_attachment_storage_permissions_invalid".into());
    }
    if metadata.mode() & 0o077 != 0 {
        return Err("chat_attachment_storage_permissions_invalid".into());
    }
    Ok(())
}

fn cleanup_unclaimed_chat_attachment_files(root: &Path) {
    let Ok(registry) = chat_attachments().lock() else {
        return;
    };
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(file_name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Some(attachment_id) = file_name.strip_suffix(".bin") else {
            continue;
        };
        if !registry.contains_key(attachment_id) {
            let _ = fs::remove_file(path);
        }
    }
}

fn store_chat_attachment(
    request: ChatAttachmentUploadRequest,
) -> Result<ChatAttachmentUploadResult, String> {
    let file_name = validate_chat_attachment_file_name(&request.file_name)?;
    let mime_type = canonical_chat_attachment_mime(&file_name, &request.mime_type)?;
    // Reject obviously oversized encoded input before decoding. The exact byte
    // check below remains authoritative for padded/invalid base64.
    if request.content_base64.len() > ((CHAT_ATTACHMENT_MAX_BYTES * 4) / 3) + 8 {
        return Err("chat_attachment_too_large".into());
    }
    let bytes = BASE64_STANDARD
        .decode(request.content_base64.as_bytes())
        .map_err(|_| "chat_attachment_invalid_encoding".to_string())?;
    if bytes.is_empty() {
        return Err("chat_attachment_empty".into());
    }
    if bytes.len() > CHAT_ATTACHMENT_MAX_BYTES {
        return Err("chat_attachment_too_large".into());
    }

    let root = chat_attachment_root();
    if fs::symlink_metadata(&root)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err("chat_attachment_storage_permissions_invalid".into());
    }
    fs::create_dir_all(&root).map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
        .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
    validate_private_attachment_directory(&root)?;
    cleanup_unclaimed_chat_attachment_files(&root);

    let attachment_id = uuid::Uuid::new_v4().simple().to_string();
    let path = root.join(format!("{attachment_id}.bin"));
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
    if let Err(error) = (|| -> Result<(), String> {
        file.write_all(&bytes)
            .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
        file.sync_all()
            .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|_| "chat_attachment_storage_unavailable".to_string())?;
        validate_private_attachment_path(&path)
    })() {
        let _ = fs::remove_file(&path);
        return Err(error);
    }

    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    let sha256 = format!("{:x}", hasher.finalize());
    let stored = StoredChatAttachment {
        path: path.clone(),
        file_name: file_name.clone(),
        mime_type: mime_type.clone(),
        byte_size: bytes.len(),
        sha256: sha256.clone(),
    };
    let mut registry = chat_attachments()
        .lock()
        .map_err(|_| "chat_attachment_registry_unavailable".to_string())?;
    let registry_bytes = registry
        .values()
        .map(|attachment| attachment.byte_size)
        .sum::<usize>();
    if registry.len() >= 64
        || registry_bytes.saturating_add(bytes.len()) > CHAT_ATTACHMENT_MAX_REGISTRY_BYTES
    {
        let _ = fs::remove_file(&path);
        return Err("chat_attachment_registry_full".into());
    }
    registry.insert(attachment_id.clone(), stored);
    Ok(ChatAttachmentUploadResult {
        attachment_id,
        file_name,
        mime_type,
        byte_size: bytes.len(),
        sha256,
    })
}

struct LoadedChatAttachment {
    file_name: String,
    mime_type: String,
    bytes: Vec<u8>,
    byte_size: usize,
}

fn take_chat_attachment(attachment_id: &str) -> Result<LoadedChatAttachment, String> {
    if attachment_id.is_empty()
        || attachment_id.len() > 128
        || !attachment_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err("chat_attachment_invalid_reference".into());
    }
    let stored = chat_attachments()
        .lock()
        .map_err(|_| "chat_attachment_registry_unavailable".to_string())?
        .remove(attachment_id)
        .ok_or_else(|| "chat_attachment_reference_expired".to_string())?;
    if let Err(error) = validate_private_attachment_path(&stored.path) {
        let _ = fs::remove_file(&stored.path);
        return Err(error);
    }
    let bytes = match fs::read(&stored.path) {
        Ok(bytes) => bytes,
        Err(_) => {
            let _ = fs::remove_file(&stored.path);
            return Err("chat_attachment_read_failed".into());
        }
    };
    let _ = fs::remove_file(&stored.path);
    if bytes.len() != stored.byte_size || bytes.len() > CHAT_ATTACHMENT_MAX_BYTES {
        return Err("chat_attachment_size_changed".into());
    }
    let mut hasher = Sha256::new();
    hasher.update(&bytes);
    if format!("{:x}", hasher.finalize()) != stored.sha256 {
        return Err("chat_attachment_integrity_failed".into());
    }
    Ok(LoadedChatAttachment {
        file_name: stored.file_name,
        mime_type: stored.mime_type,
        bytes,
        byte_size: stored.byte_size,
    })
}

fn gateway_messages_payload(
    request: &GatewayProxyRequest,
) -> Result<Vec<serde_json::Value>, String> {
    gateway_messages_payload_with_native_mime_types(request, &HashMap::new())
}

fn gateway_messages_payload_with_native_mime_types(
    request: &GatewayProxyRequest,
    native_mime_limits: &HashMap<String, Option<usize>>,
) -> Result<Vec<serde_json::Value>, String> {
    let mut total_attachment_bytes = 0usize;
    let mut messages = Vec::with_capacity(request.messages.len());
    for message in &request.messages {
        if message.content.len() > GATEWAY_MAX_CONTENT_BYTES {
            return Err("gateway_request_too_large".into());
        }
        let mut loaded_attachments = Vec::with_capacity(message.attachments.len());
        for attachment in &message.attachments {
            let stored = take_chat_attachment(&attachment.attachment_id)?;
            total_attachment_bytes = total_attachment_bytes
                .checked_add(stored.byte_size)
                .ok_or("gateway_request_too_large")?;
            if total_attachment_bytes > CHAT_ATTACHMENT_MAX_TOTAL_BYTES {
                return Err("gateway_request_too_large".into());
            }
            if !is_gateway_text_attachment_mime(&stored.mime_type)
                && (!is_gateway_native_attachment_mime(&stored.mime_type)
                    || !native_mime_limits.contains_key(&stored.mime_type))
            {
                return Err(format!(
                    "gateway_attachment_unsupported:{}",
                    stored.mime_type
                ));
            }
            if let Some(Some(max_bytes)) = native_mime_limits.get(&stored.mime_type) {
                if stored.byte_size > *max_bytes {
                    return Err(format!("gateway_attachment_too_large:{}", stored.mime_type));
                }
            }
            if is_gateway_text_attachment_mime(&stored.mime_type) {
                String::from_utf8(stored.bytes.clone())
                    .map_err(|_| "gateway_attachment_invalid_utf8".to_string())?;
            }
            loaded_attachments.push(stored);
        }

        let has_native_attachment = loaded_attachments
            .iter()
            .any(|attachment| is_gateway_native_attachment_mime(&attachment.mime_type));
        let content = if !has_native_attachment {
            let mut text = message.content.clone();
            for attachment in loaded_attachments {
                let attachment_text = String::from_utf8(attachment.bytes)
                    .map_err(|_| "gateway_attachment_invalid_utf8".to_string())?;
                text.push_str("\n\n[Attachment: ");
                text.push_str(&attachment.file_name);
                text.push_str("]\n");
                text.push_str(&attachment_text);
                text.push_str("\n[End attachment]");
            }
            serde_json::Value::String(text)
        } else {
            let mut parts = Vec::with_capacity(loaded_attachments.len() + 1);
            if !message.content.is_empty() {
                parts.push(serde_json::json!({
                    "type": "text",
                    "text": message.content,
                }));
            }
            for attachment in loaded_attachments {
                if is_gateway_text_attachment_mime(&attachment.mime_type) {
                    let attachment_text = String::from_utf8(attachment.bytes)
                        .map_err(|_| "gateway_attachment_invalid_utf8".to_string())?;
                    parts.push(serde_json::json!({
                        "type": "text",
                        "text": format!(
                            "[Attachment: {}]\n{}\n[End attachment]",
                            attachment.file_name, attachment_text
                        ),
                    }));
                } else if attachment.mime_type == "application/pdf" {
                    // Preserve PDFs as documents. Sending a PDF as an
                    // image_url makes the upstream provider treat it as an
                    // image (or reject the request) and loses native PDF
                    // semantics on providers such as Anthropic.
                    let encoded = BASE64_STANDARD.encode(&attachment.bytes);
                    parts.push(serde_json::json!({
                        "type": "file",
                        "file": {
                            "filename": attachment.file_name,
                            "file_data": format!("data:{};base64,{}", attachment.mime_type, encoded),
                        },
                    }));
                } else {
                    let encoded = BASE64_STANDARD.encode(&attachment.bytes);
                    parts.push(serde_json::json!({
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:{};base64,{}", attachment.mime_type, encoded),
                            "detail": "auto",
                        },
                    }));
                }
            }
            serde_json::Value::Array(parts)
        };
        messages.push(serde_json::json!({
            "role": message.role,
            "content": content,
        }));
    }
    Ok(messages)
}

static GATEWAY_CANCELLATIONS: OnceLock<
    Mutex<HashMap<String, tokio_util::sync::CancellationToken>>,
> = OnceLock::new();

fn gateway_cancellations() -> &'static Mutex<HashMap<String, tokio_util::sync::CancellationToken>> {
    GATEWAY_CANCELLATIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn validate_gateway_request(request: &GatewayProxyRequest) -> Result<(), String> {
    let request_id_is_valid = !request.request_id.is_empty()
        && request.request_id.len() <= 128
        && request
            .request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
    if !request_id_is_valid {
        return Err("gateway_invalid_request_id".into());
    }

    let model = request.model.trim();
    if model.is_empty() || model.len() > 256 {
        return Err("gateway_invalid_model".into());
    }
    if request.messages.is_empty() || request.messages.len() > GATEWAY_MAX_MESSAGES {
        return Err("gateway_invalid_message_count".into());
    }
    let content_bytes = request.messages.iter().try_fold(0usize, |total, message| {
        if !matches!(
            message.role.as_str(),
            "system" | "user" | "assistant" | "tool"
        ) {
            return Err("gateway_invalid_message_role".to_string());
        }
        if message.attachments.len() > CHAT_ATTACHMENT_MAX_REFS_PER_MESSAGE {
            return Err("gateway_attachment_count_exceeded".to_string());
        }
        for attachment in &message.attachments {
            if attachment.attachment_id.is_empty()
                || attachment.attachment_id.len() > 128
                || !attachment
                    .attachment_id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
            {
                return Err("chat_attachment_invalid_reference".to_string());
            }
        }
        total
            .checked_add(message.content.len())
            .ok_or_else(|| "gateway_request_too_large".to_string())
    })?;
    if content_bytes > GATEWAY_MAX_CONTENT_BYTES {
        return Err("gateway_request_too_large".into());
    }
    Ok(())
}

fn gateway_endpoint_from_health(health: &DaemonHealth, path: &str) -> Result<reqwest::Url, String> {
    if !health.ok || health.gateway_enabled != Some(true) {
        return Err("gateway_disabled".into());
    }
    let host = health.gateway_host.as_deref().unwrap_or("127.0.0.1");
    if !matches!(host, "127.0.0.1" | "::1" | "localhost") {
        return Err("gateway_non_loopback_host_refused".into());
    }
    let port = health
        .gateway_port
        .filter(|port| *port > 0)
        .ok_or("gateway_missing_port")?;
    let authority = if host == "::1" {
        format!("[::1]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let url = reqwest::Url::parse(&format!("http://{authority}{path}"))
        .map_err(|_| "gateway_invalid_endpoint".to_string())?;
    if url.scheme() != "http"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("gateway_invalid_endpoint".into());
    }
    Ok(url)
}

fn gateway_http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(120))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|error| format!("gateway_client_init:{error}"))
}

#[tauri::command]
async fn gateway_probe() -> Result<bool, String> {
    let health = probe_daemon_health();
    let url = gateway_endpoint_from_health(&health, "/health")?;
    let token = read_gateway_auth_token().ok_or("gateway_token_unavailable")?;
    let response = gateway_http_client()?
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|error| format!("gateway_unreachable:{error}"))?;
    Ok(response.status().is_success())
}

fn gateway_attachment_capability_result(
    mime_type: &str,
    state: &str,
    reason: impl Into<String>,
    max_bytes: Option<usize>,
) -> GatewayAttachmentCapability {
    GatewayAttachmentCapability {
        mime_type: mime_type.to_string(),
        state: state.to_string(),
        reason: reason.into(),
        max_bytes,
    }
}

fn gateway_catalog_mime_matches(accepted: &str, mime_type: &str) -> bool {
    let accepted = accepted.trim().to_ascii_lowercase();
    let mime_type = mime_type.trim().to_ascii_lowercase();
    if accepted.ends_with("/*") {
        mime_type.starts_with(accepted.trim_end_matches('*'))
    } else {
        accepted == mime_type
    }
}

fn gateway_model_accepts_attachment(
    mime_type: &str,
    capabilities: &GatewayModelIOCapabilities,
) -> (bool, Option<usize>) {
    let accepted_explicitly = capabilities
        .accepted_input_mime_types
        .iter()
        .any(|accepted| gateway_catalog_mime_matches(accepted, mime_type));
    let modality = if mime_type == "application/pdf" {
        "pdf"
    } else {
        "image"
    };
    let modality_supported = capabilities
        .input_modalities
        .iter()
        .any(|value| value.trim().eq_ignore_ascii_case(modality));
    let accepted = if capabilities.accepted_input_mime_types.is_empty() {
        modality_supported
    } else {
        accepted_explicitly
    };
    let max_bytes = (mime_type != "application/pdf")
        .then_some(capabilities.image_max_bytes)
        .flatten();
    (accepted, max_bytes)
}

async fn query_gateway_attachment_capability(
    model: &str,
    mime_type: &str,
    health: &DaemonHealth,
    token: &str,
) -> GatewayAttachmentCapability {
    let mime_type = mime_type.trim().to_ascii_lowercase();
    if is_gateway_text_attachment_mime(&mime_type) {
        return gateway_attachment_capability_result(
            &mime_type,
            "supported",
            "Text attachments are decoded by the Linux gateway.",
            None,
        );
    }
    if !is_gateway_native_attachment_mime(&mime_type) {
        return gateway_attachment_capability_result(
            &mime_type,
            "unsupported",
            "The Linux gateway does not allow this MIME type.",
            None,
        );
    }
    let url = match gateway_endpoint_from_health(health, "/v1/models/catalog") {
        Ok(url) => url,
        Err(error) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                format!("Model capability catalog is unavailable ({error})."),
                None,
            )
        }
    };
    let client = match gateway_http_client() {
        Ok(client) => client,
        Err(error) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                format!("Model capability catalog is unavailable ({error})."),
                None,
            )
        }
    };
    let response = match client.get(url).bearer_auth(token).send().await {
        Ok(response) => response,
        Err(error) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                format!("Model capability catalog is unavailable ({error})."),
                None,
            )
        }
    };
    if !response.status().is_success() {
        return gateway_attachment_capability_result(
            &mime_type,
            "unknown",
            format!(
                "Model capability catalog returned HTTP {}.",
                response.status().as_u16()
            ),
            None,
        );
    }
    let body = match response.text().await {
        Ok(body) if body.len() <= 1_048_576 => body,
        Ok(_) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                "Model capability catalog response is too large.",
                None,
            )
        }
        Err(error) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                format!("Model capability catalog could not be read ({error})."),
                None,
            )
        }
    };
    let catalog: GatewayModelCatalogResponse = match serde_json::from_str(&body) {
        Ok(catalog) => catalog,
        Err(error) => {
            return gateway_attachment_capability_result(
                &mime_type,
                "unknown",
                format!("Model capability catalog is invalid ({error})."),
                None,
            )
        }
    };
    let model = model.trim();
    let entry = catalog.data.iter().find(|entry| {
        entry.id.eq_ignore_ascii_case(model)
            || entry
                .base_model_id
                .as_deref()
                .is_some_and(|base| base.eq_ignore_ascii_case(model))
    });
    let Some(entry) = entry else {
        return gateway_attachment_capability_result(
            &mime_type,
            "unknown",
            "The selected model is absent from the daemon capability catalog.",
            None,
        );
    };
    let Some(capabilities) = entry.model_capabilities.as_ref() else {
        return gateway_attachment_capability_result(
            &mime_type,
            "unknown",
            "The selected model has no declared input capability contract.",
            None,
        );
    };
    let (accepted, max_bytes) = gateway_model_accepts_attachment(&mime_type, capabilities);
    if accepted {
        gateway_attachment_capability_result(
            &mime_type,
            "supported",
            "The daemon catalog explicitly permits this input type.",
            max_bytes,
        )
    } else {
        gateway_attachment_capability_result(
            &mime_type,
            "unsupported",
            "The selected model does not declare support for this input type.",
            max_bytes,
        )
    }
}

fn stored_chat_attachment_mime(attachment_id: &str) -> Result<String, String> {
    if attachment_id.is_empty()
        || attachment_id.len() > 128
        || !attachment_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return Err("chat_attachment_invalid_reference".into());
    }
    chat_attachments()
        .lock()
        .map_err(|_| "chat_attachment_registry_unavailable".to_string())?
        .get(attachment_id)
        .map(|attachment| attachment.mime_type.clone())
        .ok_or_else(|| "chat_attachment_reference_expired".into())
}

async fn native_attachment_mime_types_for_request(
    request: &GatewayProxyRequest,
    health: &DaemonHealth,
    token: &str,
) -> Result<HashMap<String, Option<usize>>, String> {
    let mut native_mime_limits = HashMap::new();
    let mut capability_cache: HashMap<String, GatewayAttachmentCapability> = HashMap::new();
    for message in &request.messages {
        for attachment in &message.attachments {
            let mime_type = stored_chat_attachment_mime(&attachment.attachment_id)?;
            if is_gateway_text_attachment_mime(&mime_type) {
                continue;
            }
            let capability = if let Some(capability) = capability_cache.get(&mime_type) {
                capability.clone()
            } else {
                let capability =
                    query_gateway_attachment_capability(&request.model, &mime_type, health, token)
                        .await;
                capability_cache.insert(mime_type.clone(), capability.clone());
                capability
            };
            match capability.state.as_str() {
                "supported" => {
                    native_mime_limits.insert(mime_type, capability.max_bytes);
                }
                "unsupported" => {
                    return Err(format!(
                        "gateway_attachment_unsupported:{}",
                        capability.mime_type
                    ));
                }
                _ => return Err("gateway_attachment_capability_unavailable".into()),
            }
        }
    }
    Ok(native_mime_limits)
}

#[tauri::command]
async fn gateway_attachment_capability(
    model: String,
    mime_type: String,
) -> Result<GatewayAttachmentCapability, String> {
    let normalized_mime_type = mime_type.trim().to_ascii_lowercase();
    if normalized_mime_type.is_empty() || normalized_mime_type.len() > 128 {
        return Ok(gateway_attachment_capability_result(
            &normalized_mime_type,
            "unsupported",
            "The attachment MIME type is invalid.",
            None,
        ));
    }
    if is_gateway_text_attachment_mime(&normalized_mime_type) {
        return Ok(query_gateway_attachment_capability(
            &model,
            &normalized_mime_type,
            &DaemonHealth::default(),
            "",
        )
        .await);
    }
    let health = probe_daemon_health();
    let Some(token) = read_gateway_auth_token() else {
        return Ok(gateway_attachment_capability_result(
            &normalized_mime_type,
            "unknown",
            "Gateway authentication is unavailable for model capability lookup.",
            None,
        ));
    };
    Ok(query_gateway_attachment_capability(&model, &normalized_mime_type, &health, &token).await)
}

async fn run_gateway_chat_stream(
    request: &GatewayProxyRequest,
    on_event: &Channel<String>,
    cancellation: &tokio_util::sync::CancellationToken,
) -> Result<(), String> {
    validate_gateway_request(request)?;
    let health = probe_daemon_health();
    let url = gateway_endpoint_from_health(&health, "/v1/chat/completions")?;
    let token = read_gateway_auth_token().ok_or("gateway_token_unavailable")?;
    let native_mime_limits =
        native_attachment_mime_types_for_request(request, &health, &token).await?;
    let messages = gateway_messages_payload_with_native_mime_types(request, &native_mime_limits)?;
    let body = serde_json::json!({
        "model": request.model.trim(),
        "stream": true,
        "stream_options": { "include_usage": true },
        "messages": messages,
    });
    let send = gateway_http_client()?
        .post(url)
        .bearer_auth(token)
        .header(reqwest::header::ACCEPT, "text/event-stream")
        .json(&body)
        .send();
    let response = tokio::select! {
        _ = cancellation.cancelled() => return Err("gateway_aborted".into()),
        result = send => result.map_err(|error| format!("gateway_unreachable:{error}"))?,
    };

    let status = response.status();
    if !status.is_success() {
        let detail = response.text().await.unwrap_or_default();
        let bounded = detail.chars().take(4096).collect::<String>();
        return Err(format!("gateway_http:{}:{bounded}", status.as_u16()));
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    if !content_type
        .split(';')
        .next()
        .is_some_and(|mime| mime.trim().eq_ignore_ascii_case("text/event-stream"))
    {
        return Err("gateway_invalid_content_type".into());
    }

    let mut total_bytes = 0usize;
    let mut pending_utf8 = Vec::new();
    let mut stream = response.bytes_stream();
    loop {
        let next = tokio::select! {
            _ = cancellation.cancelled() => return Err("gateway_aborted".into()),
            next = stream.next() => next,
        };
        let Some(chunk) = next else { break };
        let bytes = chunk.map_err(|error| format!("gateway_stream_interrupted:{error}"))?;
        total_bytes = total_bytes
            .checked_add(bytes.len())
            .ok_or("gateway_response_too_large")?;
        if total_bytes > GATEWAY_MAX_RESPONSE_BYTES {
            return Err("gateway_response_too_large".into());
        }
        pending_utf8.extend_from_slice(&bytes);
        loop {
            match std::str::from_utf8(&pending_utf8) {
                Ok(text) => {
                    if !text.is_empty() {
                        on_event
                            .send(text.to_string())
                            .map_err(|_| "gateway_renderer_disconnected".to_string())?;
                    }
                    pending_utf8.clear();
                    break;
                }
                Err(error) => {
                    let valid_up_to = error.valid_up_to();
                    if valid_up_to > 0 {
                        let text = std::str::from_utf8(&pending_utf8[..valid_up_to])
                            .map_err(|_| "gateway_invalid_utf8")?;
                        on_event
                            .send(text.to_string())
                            .map_err(|_| "gateway_renderer_disconnected".to_string())?;
                        pending_utf8.drain(..valid_up_to);
                    }
                    if error.error_len().is_some() {
                        return Err("gateway_invalid_utf8".into());
                    }
                    break;
                }
            }
        }
    }
    if !pending_utf8.is_empty() {
        return Err("gateway_invalid_utf8".into());
    }
    Ok(())
}

#[tauri::command]
fn chat_attachment_upload(
    request: ChatAttachmentUploadRequest,
) -> Result<ChatAttachmentUploadResult, String> {
    store_chat_attachment(request)
}

/// Returns the gateway bearer for the HTTP gateway client (chat stream).
/// Security note (Issue 20): this enters the renderer JS heap. Mitigations:
/// restrictive CSP (tauri.conf.json), token file over env, short-lived tokens.
/// Full fix is a Rust-side gateway proxy (Phase 4) that never returns the secret.
#[tauri::command]
async fn gateway_chat_stream(
    request: GatewayProxyRequest,
    on_event: Channel<String>,
) -> Result<(), String> {
    let cancellation = tokio_util::sync::CancellationToken::new();
    {
        let mut requests = gateway_cancellations()
            .lock()
            .map_err(|_| "gateway_cancellation_registry_poisoned")?;
        if requests.contains_key(&request.request_id) {
            return Err("gateway_duplicate_request_id".into());
        }
        requests.insert(request.request_id.clone(), cancellation.clone());
    }

    let result = run_gateway_chat_stream(&request, &on_event, &cancellation).await;
    if let Ok(mut requests) = gateway_cancellations().lock() {
        requests.remove(&request.request_id);
    }
    result
}

#[tauri::command]
fn gateway_chat_cancel(request_id: String) -> Result<(), String> {
    let requests = gateway_cancellations()
        .lock()
        .map_err(|_| "gateway_cancellation_registry_poisoned")?;
    if let Some(cancellation) = requests.get(&request_id) {
        cancellation.cancel();
    }
    Ok(())
}

fn probe_daemon_health() -> DaemonHealth {
    probe_daemon_health_with_timeout(Duration::from_secs(5), false)
}

fn probe_authenticated_daemon_health(timeout: Duration) -> DaemonHealth {
    probe_daemon_health_with_timeout(timeout, true)
}

fn probe_daemon_health_with_timeout(timeout: Duration, require_auth: bool) -> DaemonHealth {
    let socket_path = linux_socket_path();
    let auth_token = read_auth_token();
    if require_auth && auth_token.is_none() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Daemon socket auth token is unavailable".into()),
            ..Default::default()
        };
    }
    let mut stream = match UnixStream::connect(&socket_path) {
        Ok(s) => s,
        Err(e) => {
            return DaemonHealth {
                ok: false,
                socket_path: Some(socket_path.display().to_string()),
                error: Some(e.to_string()),
                ..Default::default()
            };
        }
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut envelope = serde_json::json!({
        "protocolVersion": 1,
        "id": format!("health-{stamp}"),
        "method": "daemon.health",
        "traceId": format!("trace-{stamp}"),
    });
    if let Some(token) = auth_token {
        envelope["authToken"] = serde_json::Value::String(token);
    }
    let payload = format!("{envelope}\n");
    if stream.write_all(payload.as_bytes()).is_err() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Failed to write health request".into()),
            ..Default::default()
        };
    }

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    if reader.read_line(&mut line).is_err() {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some("Failed to read health response".into()),
            ..Default::default()
        };
    }
    let parsed: serde_json::Value = match serde_json::from_str(line.trim()) {
        Ok(v) => v,
        Err(e) => {
            return DaemonHealth {
                ok: false,
                socket_path: Some(socket_path.display().to_string()),
                error: Some(format!("Invalid JSON response: {e}")),
                ..Default::default()
            };
        }
    };
    if let Some(err) = parsed
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(|m| m.as_str())
    {
        return DaemonHealth {
            ok: false,
            socket_path: Some(socket_path.display().to_string()),
            error: Some(err.to_string()),
            ..Default::default()
        };
    }
    let result = parsed
        .get("result")
        .cloned()
        .unwrap_or(serde_json::json!({}));
    DaemonHealth {
        ok: result.get("ok").and_then(|v| v.as_bool()).unwrap_or(false),
        protocol_version: result
            .get("protocolVersion")
            .and_then(|v| v.as_u64())
            .map(|v| v as u32),
        daemon_version: result
            .get("daemonVersion")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        socket_path: Some(
            result
                .get("socketPath")
                .and_then(|v| v.as_str())
                .map(str::to_string)
                .unwrap_or_else(|| socket_path.display().to_string()),
        ),
        gateway_enabled: result.get("gatewayEnabled").and_then(|v| v.as_bool()),
        gateway_host: result
            .get("gatewayHost")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        gateway_port: result
            .get("gatewayPort")
            .and_then(|v| v.as_u64())
            .map(|v| v as u16),
        error: None,
    }
}
