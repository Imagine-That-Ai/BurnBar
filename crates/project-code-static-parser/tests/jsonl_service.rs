use serde_json::{json, Value};
use std::error::Error;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};

#[test]
fn handles_multiple_jsonl_requests_in_one_process() -> Result<(), Box<dyn Error>> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_project-code-static-parser"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or("missing parser stdin")?;
    let stdout = child.stdout.take().ok_or("missing parser stdout")?;
    let mut reader = BufReader::new(stdout);

    for (request_id, file_path, symbol_name) in [
        ("request-one", "one.py", "first_symbol"),
        ("request-two", "two.py", "second_symbol"),
    ] {
        let request = json!({
            "requestId": request_id,
            "filePath": file_path,
            "language": "python",
            "blobSha": request_id,
            "text": format!("def {symbol_name}():\n    return 1\n")
        });
        writeln!(stdin, "{request}")?;
        stdin.flush()?;

        let mut line = String::new();
        let bytes = reader.read_line(&mut line)?;
        assert!(bytes > 0, "parser closed stdout before responding");
        let response: Value = serde_json::from_str(&line)?;
        assert_eq!(response["requestId"], request_id);
        assert_eq!(response["filePath"], file_path);
        assert_eq!(response["ok"], true);
        assert_eq!(response["shaMatch"], false);
        assert!(
            response["symbols"].as_array().is_some_and(|symbols| {
                symbols.iter().any(|symbol| symbol["name"] == symbol_name)
            }),
            "missing parsed symbol {symbol_name}: {response}"
        );
    }

    drop(stdin);
    let status = child.wait()?;
    assert!(status.success(), "parser exited with {status}");
    Ok(())
}

#[test]
fn emits_true_blob_integrity_state() -> Result<(), Box<dyn Error>> {
    let text = "def answer():\n    return 42\n";
    let request = json!({
        "requestId": "sha-match",
        "filePath": "answer.py",
        "language": "python",
        "blobSha": "eca386f51bbe9df459d3def8a91f74e99caeab92",
        "text": text,
    });
    let output = Command::new(env!("CARGO_BIN_EXE_project-code-static-parser"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut child = output;
    let mut stdin = child.stdin.take().ok_or("missing parser stdin")?;
    let stdout = child.stdout.take().ok_or("missing parser stdout")?;
    writeln!(stdin, "{request}")?;
    stdin.flush()?;
    drop(stdin);
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let response: Value = serde_json::from_str(&line)?;
    assert_eq!(response["ok"], true);
    assert_eq!(response["shaMatch"], true);
    assert!(child.wait()?.success());
    Ok(())
}
