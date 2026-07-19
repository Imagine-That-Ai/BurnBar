use openburnbar_domain_ffi::{
    hermes_ratchet_prekey_shared_secret, HermesFfiError, HermesRatchetPrekeyRequest,
};

const PUBLIC_KEY: &str =
    "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=";

fn request(dh1: Vec<u8>, initiator_key: &str) -> HermesRatchetPrekeyRequest {
    HermesRatchetPrekeyRequest {
        dh1,
        dh2: vec![0x22; 32],
        dh3: vec![0x33; 32],
        uid: "uid".into(),
        client_id: "client".into(),
        initiator_role: "agent".into(),
        initiator_identity_public_key_base64: initiator_key.into(),
        responder_identity_public_key_base64: PUBLIC_KEY.into(),
        initiator_signed_prekey_public_key_base64: PUBLIC_KEY.into(),
        responder_signed_prekey_public_key_base64: PUBLIC_KEY.into(),
        initiator_initial_ratchet_public_key_base64: PUBLIC_KEY.into(),
    }
}

#[test]
fn composite_prekey_ffi_rejects_malformed_secrets_and_public_points() {
    assert!(matches!(
        hermes_ratchet_prekey_shared_secret(request(vec![0x11; 31], PUBLIC_KEY)),
        Err(HermesFfiError::InvalidRatchetSharedSecretLength)
    ));
    assert!(matches!(
        hermes_ratchet_prekey_shared_secret(request(
            vec![0x11; 32],
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
        )),
        Err(HermesFfiError::InvalidP256PublicKey)
    ));
    assert!(matches!(
        hermes_ratchet_prekey_shared_secret(request(vec![0x11; 32], "not-base64")),
        Err(HermesFfiError::InvalidP256PublicKey)
    ));
}
