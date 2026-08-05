//! Diagnostic probe: runs the exact `IrohEndpointHandle::bootstrap` path the
//! macOS host uses, printing the real error instead of the OSLog-hashed one.
//!
//! Usage:
//!     cargo run --example bootstrap_probe -- [relay_url] [secret_hex]
//!
//! `relay_url` defaults to the production Remote Config value; pass `""` to
//! exercise the n0 default relay mesh. `secret_hex` is 64 hex chars (32 bytes);
//! when omitted a deterministic throwaway key is used. The probe never reads
//! or mutates the Keychain — pass the secret explicitly if you need to
//! reproduce a specific NodeId.

use openburnbar_iroh::{IrohEndpointHandle, IrohSecretKeyMaterial};

fn parse_secret(hex: &str) -> Option<Vec<u8>> {
    let hex = hex.trim();
    if hex.len() != 64 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    (0..32)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok())
        .collect()
}

fn main() {
    let mut args = std::env::args().skip(1);
    let relay_url = args
        .next()
        .unwrap_or_else(|| "https://use1-1.relay.alberto8793.burnbar.iroh.link/".to_string());
    let raw = match args.next() {
        Some(hex) => match parse_secret(&hex) {
            Some(bytes) => {
                println!("secret     = supplied (32 bytes)");
                bytes
            }
            None => {
                eprintln!("secret_hex must be exactly 64 hex characters");
                std::process::exit(2);
            }
        },
        None => {
            println!("secret     = throwaway");
            (0u8..32).collect()
        }
    };

    println!(
        "relay_mode = {}",
        if relay_url.trim().is_empty() {
            "Default (n0 public mesh)".to_string()
        } else {
            format!("Custom({relay_url})")
        }
    );

    let handle = IrohEndpointHandle::new();
    let started = std::time::Instant::now();
    match handle
        .clone()
        .bootstrap(IrohSecretKeyMaterial { raw }, relay_url)
    {
        Ok(identity) => {
            println!("BOOTSTRAP OK in {:?}", started.elapsed());
            println!("  node_id          = {}", identity.node_id);
            println!("  relay_url        = {}", identity.relay_url);
            println!("  direct_addresses = {:?}", identity.direct_addresses);
        }
        Err(err) => {
            println!("BOOTSTRAP FAILED in {:?}", started.elapsed());
            println!("  error = {err}");
            println!("  debug = {err:?}");
        }
    }
    let _ = handle.shutdown();
}
