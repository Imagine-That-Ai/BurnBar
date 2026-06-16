// SPDX-License-Identifier: AGPL-3.0-only

use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, Write};
use tree_sitter::{Language, Node, Parser};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    request_id: Option<String>,
    file_path: String,
    language: Option<String>,
    blob_sha: String,
    text: String,
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
struct TierEvidence {
    parser: String,
    language: String,
    blob_sha: String,
    sha_match: bool,
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
                errors: vec![format!("stdin read failed: {error}")],
            },
        };
        if serde_json::to_writer(&mut stdout, &response).is_err() {
            break;
        }
        if writeln!(&mut stdout).is_err() {
            break;
        }
    }
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
            errors: vec![format!("invalid request json: {error}")],
        },
    }
}

fn parse_request(request: ParseRequest) -> ParseResponse {
    let language_name = normalize_language(request.language.as_deref(), &request.file_path);
    let Some(language) = language_for(&language_name) else {
        return ParseResponse {
            request_id: request.request_id,
            file_path: request.file_path,
            language: language_name,
            blob_sha: request.blob_sha,
            ok: false,
            has_parse_error: false,
            symbols: Vec::new(),
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
            errors: vec!["parser returned no syntax tree".to_string()],
        };
    };

    let mut symbols = Vec::new();
    collect_symbols(
        tree.root_node(),
        request.text.as_bytes(),
        &language_name,
        &request.blob_sha,
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
        _ => match file_path.rsplit('.').next().unwrap_or_default().to_ascii_lowercase().as_str() {
            "py" => "python".to_string(),
            "swift" => "swift".to_string(),
            "ts" => "typescript".to_string(),
            "tsx" => "tsx".to_string(),
            _ => raw,
        },
    }
}

fn collect_symbols(
    node: Node<'_>,
    source: &[u8],
    language: &str,
    blob_sha: &str,
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
                sha_match: true,
            },
        });
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_symbols(child, source, language, blob_sha, symbols);
    }
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
        ) {
            if text(child, source).is_some() {
                return Some(child);
            }
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
        });

        assert!(response.ok);
        assert!(response.symbols.iter().any(|symbol| symbol.name == "Runner" && symbol.kind == "struct"));
        assert!(response.symbols.iter().any(|symbol| symbol.name == "start" && symbol.kind == "function"));
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
        });

        assert!(response.ok);
        assert!(response.symbols.iter().any(|symbol| symbol.name == "Worker" && symbol.kind == "class"));
        assert!(response.symbols.iter().any(|symbol| symbol.name == "run" && symbol.kind == "function"));
    }

    #[test]
    fn extracts_typescript_symbols() {
        let response = parse_request(ParseRequest {
            request_id: Some("typescript".to_string()),
            file_path: "app.ts".to_string(),
            language: None,
            blob_sha: "blob-ts".to_string(),
            text: "interface Job {}\nexport function runJob() {}\nconst value = 1;\n".to_string(),
        });

        assert!(response.ok);
        assert!(response.symbols.iter().any(|symbol| symbol.name == "Job" && symbol.kind == "interface"));
        assert!(response.symbols.iter().any(|symbol| symbol.name == "runJob" && symbol.kind == "function"));
        assert!(response.symbols.iter().any(|symbol| symbol.name == "value" && symbol.kind == "variable"));
    }
}
