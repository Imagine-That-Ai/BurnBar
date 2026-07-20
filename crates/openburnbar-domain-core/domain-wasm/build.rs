#[path = "../build-support/source_fingerprint.rs"]
mod source_fingerprint;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    source_fingerprint::emit_verified_source_fingerprint()
}
