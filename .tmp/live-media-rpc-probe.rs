use std::env;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

fn main() {
    let token_path = env::var("OPENBURNBAR_PROBE_TOKEN")
        .unwrap_or_else(|_| "/home/burnbar/.local/share/openburnbar/daemon-socket-auth-token".into());
    let token = fs::read_to_string(token_path).expect("read daemon auth token");
    let methods: Vec<String> = env::args().skip(1).collect();
    assert!(!methods.is_empty(), "pass at least one RPC method");
    for (index, method) in methods.iter().enumerate() {
        let mut stream = UnixStream::connect("/run/user/1000/openburnbar/daemon.sock")
            .expect("connect daemon socket");
        let request = format!(
            "{{\"protocolVersion\":1,\"id\":\"live-media-probe-{index}\",\"method\":\"{method}\",\"traceId\":\"live-media-probe\",\"params\":{{}},\"authToken\":\"{}\"}}\n",
            token.trim()
        );
        stream
            .write_all(request.as_bytes())
            .expect("write daemon request");
        let mut response = String::new();
        BufReader::new(stream)
            .read_line(&mut response)
            .expect("read daemon response");
        println!("{method}: {}", response.trim());
    }
}
