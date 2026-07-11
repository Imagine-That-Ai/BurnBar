fn main() {
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=src/capability.rs");
    println!("cargo:rerun-if-changed=src/capture.rs");
    println!("cargo:rerun-if-changed=src/decode.rs");
}
