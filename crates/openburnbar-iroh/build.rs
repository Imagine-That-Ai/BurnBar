fn main() {
    // Procedural-macro UniFFI v0.28 does not require a build script for
    // scaffolding generation, but we keep one in place so editors that
    // expect `build.rs` for FFI crates don't complain and so we can add
    // `cargo:rerun-if-changed` hooks if the API surface grows.
    println!("cargo:rerun-if-changed=src/lib.rs");
}
