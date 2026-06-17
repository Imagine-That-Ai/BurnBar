// SPDX-License-Identifier: AGPL-3.0-only

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;
use tree_sitter::{Language, Node, Parser};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    request_id: Option<String>,
    file_path: String,
    language: Option<String>,
    blob_sha: String,
    text: String,
    root_path: Option<String>,
    operation: Option<String>,
    position: Option<LspPosition>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ParseResponse {
    request_id: Option<String>,
    file_path: String,
    language: String,
    blob_sha: String,
    ok: bool,
    has_parse_error: bool,
    symbols: Vec<ParsedSymbol>,
    references: Vec<ParsedReference>,
    errors: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ParsedSymbol {
    name: String,
    kind: String,
    start_line: usize,
    end_line: usize,
    confidence_tier: String,
    evidence: TierEvidence,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ParsedReference {
    file_path: String,
    start_line: usize,
    end_line: usize,
    start_character: usize,
    end_character: usize,
    confidence_tier: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TierEvidence {
    parser: String,
    language: String,
    blob_sha: String,
    sha_match: bool,
    lsp_responded: bool,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct LspPosition {
    line: usize,
    character: usize,
}

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout());
    for line in stdin.lock().lines() {
        let response = match line {
            Ok(raw) if raw.trim().is_empty() => continue,
            Ok(raw) => parse_line(&raw),
            Err(error) => ParseResponse {
                request_id: None,
                file_path: String::new(),
                language: String::new(),
                blob_sha: String::new(),
                ok: false,
                has_parse_error: false,
                symbols: Vec::new(),
                references: Vec::new(),
                errors: vec![format!("stdin read failed: {error}")],
            },
        };
        if serde_json::to_writer(&mut stdout, &response).is_err() {
            break;
        }
        if writeln!(&mut stdout).is_err() {
            break;
        }
        if stdout.flush().is_err() {
            break;
        }
    }
    shutdown_lsp_pool();
}

fn parse_line(raw: &str) -> ParseResponse {
    match serde_json::from_str::<ParseRequest>(raw) {
        Ok(request) => parse_request(request),
        Err(error) => ParseResponse {
            request_id: None,
            file_path: String::new(),
            language: String::new(),
            blob_sha: String::new(),
            ok: false,
            has_parse_error: false,
            symbols: Vec::new(),
            references: Vec::new(),
            errors: vec![format!("invalid request json: {error}")],
        },
    }
}

fn parse_request(request: ParseRequest) -> ParseResponse {
    let language_name = normalize_language(request.language.as_deref(), &request.file_path);
    let sha_match = blob_sha_matches(&request.text, &request.blob_sha);
    if request.operation.as_deref() == Some("references") {
        return parse_lsp_references_request(request, language_name, sha_match);
    }
    if let Some(symbols) = lsp_document_symbols(&request, &language_name, sha_match) {
        return ParseResponse {
            request_id: request.request_id,
            file_path: request.file_path,
            language: language_name,
            blob_sha: request.blob_sha,
            ok: true,
            has_parse_error: false,
            symbols,
            references: Vec::new(),
            errors: Vec::new(),
        };
    }
    let Some(language) = language_for(&language_name) else {
        return ParseResponse {
            request_id: request.request_id,
            file_path: request.file_path,
            language: language_name,
            blob_sha: request.blob_sha,
            ok: false,
            has_parse_error: false,
            symbols: Vec::new(),
            references: Vec::new(),
            errors: vec!["unsupported language".to_string()],
        };
    };

    let mut parser = Parser::new();
    if let Err(error) = parser.set_language(&language) {
        return ParseResponse {
            request_id: request.request_id,
            file_path: request.file_path,
            language: language_name,
            blob_sha: request.blob_sha,
            ok: false,
            has_parse_error: false,
            symbols: Vec::new(),
            references: Vec::new(),
            errors: vec![format!("parser language load failed: {error}")],
        };
    }
    let Some(tree) = parser.parse(&request.text, None) else {
        return ParseResponse {
            request_id: request.request_id,
            file_path: request.file_path,
            language: language_name,
            blob_sha: request.blob_sha,
            ok: false,
            has_parse_error: false,
            symbols: Vec::new(),
            references: Vec::new(),
            errors: vec!["parser returned no syntax tree".to_string()],
        };
    };

    let mut symbols = Vec::new();
    // Tier-evidence integrity: confirm the text we parsed actually hashes to the
    // blob_sha the caller claimed (a git blob object id is SHA-1 of
    // "blob <len>\0<bytes>"). This is complementary to the daemon's on-disk
    // staleness check (`isCurrentBlob`): it catches a caller that passed text not
    // corresponding to the named blob, so `shaMatch` is a real signal, never a constant.
    collect_symbols(
        tree.root_node(),
        request.text.as_bytes(),
        &language_name,
        &request.blob_sha,
        sha_match,
        &mut symbols,
    );
    ParseResponse {
        request_id: request.request_id,
        file_path: request.file_path,
        language: language_name,
        blob_sha: request.blob_sha,
        ok: true,
        has_parse_error: tree.root_node().has_error(),
        symbols,
        references: Vec::new(),
        errors: Vec::new(),
    }
}

fn language_for(language: &str) -> Option<Language> {
    match language {
        "python" => Some(tree_sitter_python::LANGUAGE.into()),
        "swift" => Some(tree_sitter_swift::LANGUAGE.into()),
        "typescript" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        _ => None,
    }
}

fn normalize_language(language: Option<&str>, file_path: &str) -> String {
    let raw = language.unwrap_or_default().trim().to_ascii_lowercase();
    match raw.as_str() {
        "py" | "python" => "python".to_string(),
        "swift" => "swift".to_string(),
        "ts" | "typescript" => "typescript".to_string(),
        "tsx" => "tsx".to_string(),
        _ => match file_path
            .rsplit('.')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str()
        {
            "py" => "python".to_string(),
            "swift" => "swift".to_string(),
            "ts" => "typescript".to_string(),
            "tsx" => "tsx".to_string(),
            _ => raw,
        },
    }
}

fn parse_lsp_references_request(
    request: ParseRequest,
    language_name: String,
    sha_match: bool,
) -> ParseResponse {
    let references = request
        .position
        .and_then(|position| lsp_references(&request, &language_name, position));
    let ok = references.is_some();
    let errors = if ok {
        Vec::new()
    } else if request.position.is_none() {
        vec!["lsp reference position missing".to_string()]
    } else if sha_match {
        vec!["lsp references unavailable".to_string()]
    } else {
        vec!["lsp references unavailable; blobSha did not match text".to_string()]
    };
    ParseResponse {
        request_id: request.request_id,
        file_path: request.file_path,
        language: language_name,
        blob_sha: request.blob_sha,
        ok,
        has_parse_error: false,
        symbols: Vec::new(),
        references: references.unwrap_or_default(),
        errors,
    }
}

fn lsp_document_symbols(
    request: &ParseRequest,
    language: &str,
    sha_match: bool,
) -> Option<Vec<ParsedSymbol>> {
    let result = with_lsp_session(language, request, |session| {
        let uri = document_uri(request);
        session.open_document(language, request, &uri)?;
        session.request(
            "textDocument/documentSymbol",
            json!({"textDocument": {"uri": uri}}),
        )
    })
    .ok()?;
    let mut symbols = Vec::new();
    collect_lsp_symbols(
        &result,
        language,
        &request.blob_sha,
        sha_match,
        &mut symbols,
    );
    if symbols.is_empty() {
        None
    } else {
        Some(symbols)
    }
}

fn lsp_references(
    request: &ParseRequest,
    language: &str,
    position: LspPosition,
) -> Option<Vec<ParsedReference>> {
    let result = with_lsp_session(language, request, |session| {
        let uri = document_uri(request);
        session.open_document(language, request, &uri)?;
        session.request(
            "textDocument/references",
            json!({
                "textDocument": {"uri": uri},
                "position": position,
                "context": {"includeDeclaration": true}
            }),
        )
    })
    .ok()?;
    parse_lsp_references_result(&result, request.root_path.as_deref())
}

#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
enum LspCommandConfig {
    Args(Vec<String>),
    Object {
        command: Vec<String>,
        #[serde(default, rename = "allowedExecutables")]
        allowed_executables: Vec<String>,
    },
}

impl LspCommandConfig {
    fn parts(self) -> (Vec<String>, Vec<String>) {
        match self {
            Self::Args(parts) => (parts, Vec::new()),
            Self::Object {
                command,
                allowed_executables,
            } => (command, allowed_executables),
        }
    }
}

struct LspSession {
    child: Child,
    stdin: ChildStdin,
    responses: Receiver<Result<Value, String>>,
    timeout: Duration,
    next_id: i64,
}

impl LspSession {
    fn start_with_command(
        _language: &str,
        request: &ParseRequest,
        command: &[String],
    ) -> Option<Self> {
        let (executable, args) = command.split_first()?;
        let mut child = Command::new(executable)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdin = child.stdin.take()?;
        let stdout = child.stdout.take()?;
        let responses = spawn_lsp_reader(stdout);
        let mut session = Self {
            child,
            stdin,
            responses,
            timeout: lsp_timeout(),
            next_id: 1,
        };
        let root_uri = request.root_path.as_deref().map(file_uri_for_path);
        let mut params = json!({
            "processId": serde_json::Value::Null,
            "capabilities": {}
        });
        if let Some(root_uri) = root_uri {
            params["rootUri"] = json!(root_uri);
        }
        session.request("initialize", params).ok()?;
        session.notify("initialized", json!({})).ok()?;
        Some(session)
    }

    fn open_document(
        &mut self,
        language: &str,
        request: &ParseRequest,
        uri: &str,
    ) -> Result<(), String> {
        self.notify(
            "textDocument/didOpen",
            json!({
                "textDocument": {
                    "uri": uri,
                    "languageId": language,
                    "version": 1,
                    "text": request.text
                }
            }),
        )
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        write_lsp_message(
            &mut self.stdin,
            &json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}),
        )?;
        loop {
            let payload = self
                .responses
                .recv_timeout(self.timeout)
                .map_err(|_| format!("lsp response timed out for {method}"))??;
            if payload.get("id").and_then(Value::as_i64) != Some(id) {
                continue;
            }
            if let Some(error) = payload.get("error") {
                return Err(format!("lsp {method} failed: {error}"));
            }
            return Ok(payload.get("result").cloned().unwrap_or(Value::Null));
        }
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), String> {
        write_lsp_message(
            &mut self.stdin,
            &json!({"jsonrpc": "2.0", "method": method, "params": params}),
        )
    }
}

impl Drop for LspSession {
    fn drop(&mut self) {
        let _ = self.request("shutdown", Value::Null);
        let _ = self.notify("exit", Value::Null);
        match self.child.try_wait() {
            Ok(Some(_)) => {}
            _ => {
                let _ = self.child.kill();
                let _ = self.child.wait();
            }
        }
    }
}

static LSP_POOL: OnceLock<Mutex<HashMap<String, LspSession>>> = OnceLock::new();

fn lsp_pool() -> &'static Mutex<HashMap<String, LspSession>> {
    LSP_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn with_lsp_session<T>(
    language: &str,
    request: &ParseRequest,
    work: impl FnOnce(&mut LspSession) -> Result<T, String>,
) -> Result<T, String> {
    let command =
        lsp_command_for(language).ok_or_else(|| "no allowlisted lsp command".to_string())?;
    let key = lsp_pool_key(language, request.root_path.as_deref(), &command);
    let mut pool = lsp_pool()
        .lock()
        .map_err(|_| "lsp pool lock poisoned".to_string())?;
    if !pool.contains_key(&key) {
        let session = LspSession::start_with_command(language, request, &command)
            .ok_or_else(|| "lsp session failed to start".to_string())?;
        pool.insert(key.clone(), session);
    }
    let result = {
        let session = pool
            .get_mut(&key)
            .ok_or_else(|| "lsp session missing from pool".to_string())?;
        work(session)
    };
    if result.is_err() {
        pool.remove(&key);
    }
    result
}

fn shutdown_lsp_pool() {
    if let Some(pool) = LSP_POOL.get() {
        if let Ok(mut sessions) = pool.lock() {
            sessions.clear();
        }
    }
}

fn lsp_pool_key(language: &str, root_path: Option<&str>, command: &[String]) -> String {
    format!(
        "{}\u{0}{}\u{0}{}",
        language,
        root_path.unwrap_or_default(),
        command.join("\u{0}")
    )
}

fn lsp_command_for(language: &str) -> Option<Vec<String>> {
    let raw = std::env::var("OPENBURNBAR_CODE_LSP_COMMANDS").ok()?;
    let commands: HashMap<String, LspCommandConfig> = serde_json::from_str(&raw).ok()?;
    let (parts, explicit_allowlist) = commands.get(language)?.clone().parts();
    validate_lsp_command(language, parts, explicit_allowlist)
}

fn validate_lsp_command(
    language: &str,
    parts: Vec<String>,
    explicit_allowlist: Vec<String>,
) -> Option<Vec<String>> {
    if !matches!(language, "python" | "swift" | "typescript" | "tsx") {
        return None;
    }
    if parts.is_empty() || parts.len() > 16 {
        return None;
    }
    if parts
        .iter()
        .any(|part| part.is_empty() || part.len() > 4096 || part.contains('\0'))
    {
        return None;
    }
    let executable = parts.first()?;
    let basename = Path::new(executable)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(executable);
    if basename == "env" {
        let wrapped = parts.get(1)?;
        if wrapped.starts_with('-') || wrapped.contains('=') {
            return None;
        }
        validate_lsp_command(language, parts[1..].to_vec(), explicit_allowlist)?;
        return Some(parts);
    }
    let mut allowlist = builtin_lsp_executable_allowlist();
    allowlist.extend(
        std::env::var("OPENBURNBAR_CODE_LSP_EXECUTABLE_ALLOWLIST")
            .ok()
            .into_iter()
            .flat_map(|raw| {
                raw.split(',')
                    .map(|part| part.trim().to_string())
                    .collect::<Vec<_>>()
            }),
    );
    allowlist.extend(explicit_allowlist);
    if !allowlist
        .iter()
        .any(|allowed| executable_name_matches(basename, allowed))
    {
        return None;
    }
    if matches!(basename, "sh" | "bash" | "zsh" | "fish" | "osascript") {
        return None;
    }
    if basename.starts_with("python") && parts.iter().any(|part| part == "-c") {
        return None;
    }
    Some(parts)
}

fn builtin_lsp_executable_allowlist() -> Vec<String> {
    vec![
        "sourcekit-lsp".to_string(),
        "typescript-language-server".to_string(),
        "pyright-langserver".to_string(),
        "pylsp".to_string(),
        "ruff-lsp".to_string(),
        "python".to_string(),
        "python3".to_string(),
        "node".to_string(),
        "env".to_string(),
    ]
}

fn executable_name_matches(actual: &str, allowed: &str) -> bool {
    if actual == allowed {
        return true;
    }
    allowed == "python3" && actual.starts_with("python3")
}

fn lsp_timeout() -> Duration {
    let millis = std::env::var("OPENBURNBAR_CODE_LSP_TIMEOUT_MS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .map(|value| value.clamp(100, 30_000))
        .unwrap_or(1_500);
    Duration::from_millis(millis)
}

fn spawn_lsp_reader(stdout: std::process::ChildStdout) -> Receiver<Result<Value, String>> {
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            match read_lsp_message(&mut reader) {
                Ok(Some(value)) => {
                    if sender.send(Ok(value)).is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    let _ = sender.send(Err(error));
                    break;
                }
            }
        }
    });
    receiver
}

fn read_lsp_message(reader: &mut impl BufRead) -> Result<Option<Value>, String> {
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let bytes = reader
            .read_line(&mut line)
            .map_err(|error| error.to_string())?;
        if bytes == 0 {
            return Ok(None);
        }
        let trimmed = line.trim_end_matches(['\r', '\n']);
        if trimmed.is_empty() {
            break;
        }
        if let Some((name, value)) = trimmed.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse::<usize>().ok();
            }
        }
    }
    let Some(length) = content_length else {
        return Err("lsp response missing Content-Length".to_string());
    };
    if length > lsp_max_response_bytes() {
        return Err(format!(
            "lsp response exceeded max bytes: {length} > {}",
            lsp_max_response_bytes()
        ));
    }
    let mut body = vec![0; length];
    reader
        .read_exact(&mut body)
        .map_err(|error| error.to_string())?;
    serde_json::from_slice(&body)
        .map(Some)
        .map_err(|error| error.to_string())
}

fn lsp_max_response_bytes() -> usize {
    std::env::var("OPENBURNBAR_CODE_LSP_MAX_RESPONSE_BYTES")
        .or_else(|_| std::env::var("OPENBURNBAR_CODE_HELPER_MAX_OUTPUT_BYTES"))
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .map(|value| value.clamp(16 * 1024, 8 * 1024 * 1024))
        .unwrap_or(2 * 1024 * 1024)
}

fn write_lsp_message(stdin: &mut ChildStdin, payload: &Value) -> Result<(), String> {
    let body = serde_json::to_vec(payload).map_err(|error| error.to_string())?;
    write!(stdin, "Content-Length: {}\r\n\r\n", body.len()).map_err(|error| error.to_string())?;
    stdin.write_all(&body).map_err(|error| error.to_string())?;
    stdin.flush().map_err(|error| error.to_string())
}

fn collect_lsp_symbols(
    result: &Value,
    language: &str,
    blob_sha: &str,
    sha_match: bool,
    symbols: &mut Vec<ParsedSymbol>,
) {
    let Some(items) = result.as_array() else {
        return;
    };
    for item in items {
        collect_lsp_symbol_item(item, language, blob_sha, sha_match, symbols);
    }
}

fn collect_lsp_symbol_item(
    item: &Value,
    language: &str,
    blob_sha: &str,
    sha_match: bool,
    symbols: &mut Vec<ParsedSymbol>,
) {
    let Some(name) = item.get("name").and_then(Value::as_str) else {
        return;
    };
    let kind = item
        .get("kind")
        .and_then(Value::as_u64)
        .map(lsp_symbol_kind_name)
        .unwrap_or("symbol")
        .to_string();
    let range = item
        .get("selectionRange")
        .or_else(|| item.get("range"))
        .or_else(|| {
            item.get("location")
                .and_then(|location| location.get("range"))
        });
    if let Some(range) = range {
        if let Some((start_line, end_line)) = lsp_line_range(range) {
            symbols.push(ParsedSymbol {
                name: name.to_string(),
                kind,
                start_line,
                end_line,
                confidence_tier: "exact_lsp".to_string(),
                evidence: TierEvidence {
                    parser: "lsp".to_string(),
                    language: language.to_string(),
                    blob_sha: blob_sha.to_string(),
                    sha_match,
                    lsp_responded: true,
                },
            });
        }
    }
    if let Some(children) = item.get("children").and_then(Value::as_array) {
        for child in children {
            collect_lsp_symbol_item(child, language, blob_sha, sha_match, symbols);
        }
    }
}

fn parse_lsp_references_result(
    result: &Value,
    root_path: Option<&str>,
) -> Option<Vec<ParsedReference>> {
    let items = result.as_array()?;
    let references = items
        .iter()
        .filter_map(|item| {
            let uri = item.get("uri").and_then(Value::as_str)?;
            let range = item.get("range")?;
            let file_path = relative_path_from_uri(uri, root_path);
            let start = range.get("start")?;
            let end = range.get("end")?;
            Some(ParsedReference {
                file_path,
                start_line: start.get("line")?.as_u64()? as usize + 1,
                end_line: end.get("line")?.as_u64()? as usize + 1,
                start_character: start.get("character")?.as_u64()? as usize,
                end_character: end.get("character")?.as_u64()? as usize,
                confidence_tier: "exact_lsp".to_string(),
            })
        })
        .collect::<Vec<_>>();
    Some(references)
}

fn lsp_line_range(range: &Value) -> Option<(usize, usize)> {
    let start = range.get("start")?.get("line")?.as_u64()? as usize + 1;
    let end = range.get("end")?.get("line")?.as_u64()? as usize + 1;
    Some((start, end.max(start)))
}

fn lsp_symbol_kind_name(kind: u64) -> &'static str {
    match kind {
        2 => "module",
        3 => "namespace",
        5 => "class",
        6 => "method",
        7 => "property",
        8 => "field",
        9 => "constructor",
        10 => "enum",
        11 => "interface",
        12 => "function",
        13 => "variable",
        14 => "constant",
        22 => "struct",
        23 => "event",
        24 => "operator",
        25 => "type_parameter",
        _ => "symbol",
    }
}

fn document_uri(request: &ParseRequest) -> String {
    let path = request
        .root_path
        .as_deref()
        .map(|root| join_path(root, &request.file_path))
        .unwrap_or_else(|| request.file_path.clone());
    file_uri_for_path(&path)
}

fn join_path(root: &str, relative: &str) -> String {
    if relative.starts_with('/') {
        relative.to_string()
    } else {
        format!("{}/{}", root.trim_end_matches('/'), relative)
    }
}

fn file_uri_for_path(path: &str) -> String {
    format!("file://{}", percent_encode_path(path))
}

fn relative_path_from_uri(uri: &str, root_path: Option<&str>) -> String {
    let absolute = uri
        .strip_prefix("file://")
        .map(percent_decode_path)
        .unwrap_or_else(|| uri.to_string());
    if let Some(root_path) = root_path {
        let prefix = format!("{}/", root_path.trim_end_matches('/'));
        if let Some(relative) = absolute.strip_prefix(&prefix) {
            return relative.to_string();
        }
    }
    absolute
}

fn percent_encode_path(path: &str) -> String {
    let mut encoded = String::new();
    for byte in path.as_bytes() {
        match *byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(*byte as char)
            }
            other => encoded.push_str(&format!("%{other:02X}")),
        }
    }
    encoded
}

fn percent_decode_path(path: &str) -> String {
    let mut decoded = Vec::with_capacity(path.len());
    let bytes = path.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let Ok(value) = u8::from_str_radix(&path[index + 1..index + 3], 16) {
                decoded.push(value);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(decoded)
        .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned())
}

fn collect_symbols(
    node: Node<'_>,
    source: &[u8],
    language: &str,
    blob_sha: &str,
    sha_match: bool,
    symbols: &mut Vec<ParsedSymbol>,
) {
    if let Some((name, kind)) = symbol_name_and_kind(node, source, language) {
        symbols.push(ParsedSymbol {
            name,
            kind,
            start_line: node.start_position().row + 1,
            end_line: node.end_position().row + 1,
            confidence_tier: "static_tree_sitter".to_string(),
            evidence: TierEvidence {
                parser: "tree-sitter".to_string(),
                language: language.to_string(),
                blob_sha: blob_sha.to_string(),
                sha_match,
                lsp_responded: false,
            },
        });
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_symbols(child, source, language, blob_sha, sha_match, symbols);
    }
}

/// True when `text` hashes to the claimed git blob object id. An empty claim
/// (caller supplied no blob_sha) is treated as unverifiable -> `false`.
fn blob_sha_matches(text: &str, claimed_blob_sha: &str) -> bool {
    if claimed_blob_sha.is_empty() {
        return false;
    }
    git_blob_sha1(text).eq_ignore_ascii_case(claimed_blob_sha)
}

/// Git blob object id of `text`: SHA-1 over the framed payload `"blob <len>\0<bytes>"`.
fn git_blob_sha1(text: &str) -> String {
    let content = text.as_bytes();
    let mut message = format!("blob {}\0", content.len()).into_bytes();
    message.extend_from_slice(content);
    sha1_hex(&message)
}

/// Self-contained SHA-1 (FIPS 180-1). Used only for the git blob integrity check
/// above, so the parser keeps its zero-network / zero-crypto-dependency footprint.
fn sha1_hex(data: &[u8]) -> String {
    let mut h: [u32; 5] = [
        0x6745_2301,
        0xEFCD_AB89,
        0x98BA_DCFE,
        0x1032_5476,
        0xC3D2_E1F0,
    ];
    let bit_len = (data.len() as u64).wrapping_mul(8);

    let mut message = data.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    for block in message.chunks_exact(64) {
        let mut w = [0u32; 80];
        for (index, word_bytes) in block.chunks_exact(4).enumerate() {
            w[index] =
                u32::from_be_bytes([word_bytes[0], word_bytes[1], word_bytes[2], word_bytes[3]]);
        }
        for index in 16..80 {
            w[index] = (w[index - 3] ^ w[index - 8] ^ w[index - 14] ^ w[index - 16]).rotate_left(1);
        }

        let (mut a, mut b, mut c, mut d, mut e) = (h[0], h[1], h[2], h[3], h[4]);
        for (index, &word) in w.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999u32),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
    }

    let mut hex = String::with_capacity(40);
    for word in h {
        hex.push_str(&format!("{word:08x}"));
    }
    hex
}

fn symbol_name_and_kind(node: Node<'_>, source: &[u8], language: &str) -> Option<(String, String)> {
    let kind = node.kind();
    let normalized_kind = match language {
        "python" => match kind {
            "function_definition" => "function",
            "class_definition" => "class",
            _ => return None,
        }
        .to_string(),
        "swift" => match kind {
            "function_declaration" => "function".to_string(),
            "class_declaration" => swift_type_kind(node, source),
            "struct_declaration" => "struct".to_string(),
            "enum_declaration" => "enum".to_string(),
            "protocol_declaration" => "protocol".to_string(),
            "actor_declaration" => "actor".to_string(),
            "property_declaration" => "variable".to_string(),
            _ => return None,
        },
        "typescript" | "tsx" => match kind {
            "function_declaration" => "function",
            "method_definition" => "function",
            "class_declaration" => "class",
            "interface_declaration" => "interface",
            "type_alias_declaration" => "type",
            "lexical_declaration" | "variable_declaration" => "variable",
            _ => return None,
        }
        .to_string(),
        _ => return None,
    };
    let name_node = node
        .child_by_field_name("name")
        .or_else(|| first_named_identifier(node, source));
    let name = name_node.and_then(|candidate| text(candidate, source))?;
    Some((name, normalized_kind))
}

fn swift_type_kind(node: Node<'_>, source: &[u8]) -> String {
    let declaration = text(node, source).unwrap_or_default();
    for keyword in ["struct", "enum", "protocol", "actor", "class"] {
        if declaration.split_whitespace().any(|part| part == keyword) {
            return keyword.to_string();
        }
    }
    "type".to_string()
}

fn first_named_identifier<'tree>(node: Node<'tree>, source: &[u8]) -> Option<Node<'tree>> {
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if matches!(
            child.kind(),
            "identifier" | "type_identifier" | "property_identifier"
        ) && text(child, source).is_some()
        {
            return Some(child);
        }
        if let Some(nested) = first_named_identifier(child, source) {
            return Some(nested);
        }
    }
    None
}

fn text(node: Node<'_>, source: &[u8]) -> Option<String> {
    node.utf8_text(source)
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_swift_symbols() {
        let response = parse_request(ParseRequest {
            request_id: Some("swift".to_string()),
            file_path: "Sources/App.swift".to_string(),
            language: Some("swift".to_string()),
            blob_sha: "blob-swift".to_string(),
            text: "struct Runner { func start() {} }\n".to_string(),
            root_path: None,
            operation: None,
            position: None,
        });

        assert!(response.ok);
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "Runner" && symbol.kind == "struct"));
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "start" && symbol.kind == "function"));
        assert!(response
            .symbols
            .iter()
            .all(|symbol| symbol.confidence_tier == "static_tree_sitter"));
    }

    #[test]
    fn extracts_python_symbols() {
        let response = parse_request(ParseRequest {
            request_id: Some("python".to_string()),
            file_path: "app.py".to_string(),
            language: None,
            blob_sha: "blob-python".to_string(),
            text: "class Worker:\n    def run(self):\n        pass\n".to_string(),
            root_path: None,
            operation: None,
            position: None,
        });

        assert!(response.ok);
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "Worker" && symbol.kind == "class"));
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "run" && symbol.kind == "function"));
    }

    #[test]
    fn extracts_typescript_symbols() {
        let response = parse_request(ParseRequest {
            request_id: Some("typescript".to_string()),
            file_path: "app.ts".to_string(),
            language: None,
            blob_sha: "blob-ts".to_string(),
            text: "interface Job {}\nexport function runJob() {}\nconst value = 1;\n".to_string(),
            root_path: None,
            operation: None,
            position: None,
        });

        assert!(response.ok);
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "Job" && symbol.kind == "interface"));
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "runJob" && symbol.kind == "function"));
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "value" && symbol.kind == "variable"));
    }

    #[test]
    fn git_blob_sha_matches_git_for_empty_blob() {
        // Known answer: `git hash-object -t blob /dev/null`.
        assert_eq!(
            git_blob_sha1(""),
            "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
        );
    }

    #[test]
    fn sha_match_is_true_when_blob_matches_text() {
        let text = "struct Runner { func start() {} }\n";
        let response = parse_request(ParseRequest {
            request_id: Some("swift-sha".to_string()),
            file_path: "Sources/App.swift".to_string(),
            language: Some("swift".to_string()),
            blob_sha: git_blob_sha1(text),
            text: text.to_string(),
            root_path: None,
            operation: None,
            position: None,
        });
        assert!(response.ok);
        assert!(!response.symbols.is_empty());
        assert!(response
            .symbols
            .iter()
            .all(|symbol| symbol.evidence.sha_match));
    }

    #[test]
    fn sha_match_is_false_when_blob_is_wrong_but_symbols_still_extract() {
        let response = parse_request(ParseRequest {
            request_id: Some("swift-mismatch".to_string()),
            file_path: "Sources/App.swift".to_string(),
            language: Some("swift".to_string()),
            blob_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".to_string(),
            text: "struct Runner { func start() {} }\n".to_string(),
            root_path: None,
            operation: None,
            position: None,
        });
        assert!(response.ok);
        assert!(response
            .symbols
            .iter()
            .any(|symbol| symbol.name == "Runner"));
        assert!(response
            .symbols
            .iter()
            .all(|symbol| !symbol.evidence.sha_match));
        assert!(response
            .symbols
            .iter()
            .all(|symbol| symbol.confidence_tier == "static_tree_sitter"));
    }

    #[test]
    fn references_request_without_position_returns_actionable_error() {
        let text = "struct Runner { func start() {} }\n";
        let response = parse_request(ParseRequest {
            request_id: Some("refs-missing-position".to_string()),
            file_path: "Sources/App.swift".to_string(),
            language: Some("swift".to_string()),
            blob_sha: git_blob_sha1(text),
            text: text.to_string(),
            root_path: Some("/tmp/BurnBar".to_string()),
            operation: Some("references".to_string()),
            position: None,
        });

        assert!(!response.ok);
        assert!(response.references.is_empty());
        assert!(response
            .errors
            .iter()
            .any(|error| error.contains("position missing")));
    }

    #[test]
    fn parses_lsp_reference_locations_relative_to_root() {
        let result = json!([
            {
                "uri": "file:///tmp/Burn%20Bar/Sources/App.swift",
                "range": {
                    "start": {"line": 0, "character": 7},
                    "end": {"line": 0, "character": 13}
                }
            }
        ]);

        let Some(references) = parse_lsp_references_result(&result, Some("/tmp/Burn Bar")) else {
            panic!("expected LSP reference locations to parse");
        };

        assert_eq!(references.len(), 1);
        assert_eq!(references[0].file_path, "Sources/App.swift");
        assert_eq!(references[0].start_line, 1);
        assert_eq!(references[0].end_line, 1);
        assert_eq!(references[0].start_character, 7);
        assert_eq!(references[0].end_character, 13);
        assert_eq!(references[0].confidence_tier, "exact_lsp");
    }

    #[test]
    fn lsp_command_validation_rejects_shells_and_accepts_allowlisted_python() {
        assert!(validate_lsp_command(
            "python",
            vec!["python3".to_string(), "/tmp/fake_lsp.py".to_string()],
            Vec::new()
        )
        .is_some());
        assert!(validate_lsp_command(
            "python",
            vec![
                "/usr/bin/env".to_string(),
                "python3".to_string(),
                "/tmp/fake_lsp.py".to_string()
            ],
            Vec::new()
        )
        .is_some());
        assert!(validate_lsp_command(
            "python",
            vec![
                "/usr/bin/env".to_string(),
                "-S".to_string(),
                "python3".to_string(),
                "/tmp/fake_lsp.py".to_string()
            ],
            Vec::new()
        )
        .is_none());
        assert!(validate_lsp_command(
            "python",
            vec![
                "bash".to_string(),
                "-lc".to_string(),
                "echo nope".to_string()
            ],
            vec!["bash".to_string()]
        )
        .is_none());
        assert!(validate_lsp_command(
            "python",
            vec![
                "python3".to_string(),
                "-c".to_string(),
                "print('nope')".to_string()
            ],
            Vec::new()
        )
        .is_none());
    }

    #[test]
    fn lsp_response_size_cap_is_bounded() {
        std::env::set_var("OPENBURNBAR_CODE_LSP_MAX_RESPONSE_BYTES", "1");
        assert_eq!(lsp_max_response_bytes(), 16 * 1024);
        std::env::set_var("OPENBURNBAR_CODE_LSP_MAX_RESPONSE_BYTES", "999999999");
        assert_eq!(lsp_max_response_bytes(), 8 * 1024 * 1024);
        std::env::remove_var("OPENBURNBAR_CODE_LSP_MAX_RESPONSE_BYTES");
    }
}
