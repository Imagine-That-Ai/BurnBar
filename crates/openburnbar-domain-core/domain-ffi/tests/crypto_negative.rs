use openburnbar_domain_ffi::{
    cloud_vault_aes_gcm_open_combined, cloud_vault_aes_gcm_seal_combined, hermes_open_combined,
    hermes_seal_combined,
};
use std::error::Error;

const KEY: [u8; 32] = [0x11; 32];
const WRONG_KEY: [u8; 32] = [0x12; 32];
const NONCE: [u8; 12] = [0x22; 12];
const AAD: &[u8] = b"OpenBurnBar-crypto-proof-aad";

fn cloudvault_sealed() -> Result<Vec<u8>, Box<dyn Error>> {
    Ok(cloud_vault_aes_gcm_seal_combined(
        b"secret".to_vec(),
        KEY.to_vec(),
        NONCE.to_vec(),
        AAD.to_vec(),
    )?)
}

fn hermes_sealed() -> Result<Vec<u8>, Box<dyn Error>> {
    Ok(hermes_seal_combined(
        b"secret".to_vec(),
        KEY.to_vec(),
        AAD.to_vec(),
        NONCE.to_vec(),
    )?)
}

#[test]
fn wrong_key_rejects_cloudvault_and_hermes() -> Result<(), Box<dyn Error>> {
    assert!(cloud_vault_aes_gcm_open_combined(
        cloudvault_sealed()?,
        WRONG_KEY.to_vec(),
        AAD.to_vec()
    )
    .is_err());
    assert!(hermes_open_combined(hermes_sealed()?, WRONG_KEY.to_vec(), AAD.to_vec()).is_err());
    Ok(())
}

#[test]
fn wrong_aad_rejects_cloudvault_and_hermes() -> Result<(), Box<dyn Error>> {
    let wrong_aad = b"OpenBurnBar-crypto-proof-wrong-aad".to_vec();
    assert!(cloud_vault_aes_gcm_open_combined(
        cloudvault_sealed()?,
        KEY.to_vec(),
        wrong_aad.clone()
    )
    .is_err());
    assert!(hermes_open_combined(hermes_sealed()?, KEY.to_vec(), wrong_aad).is_err());
    Ok(())
}

#[test]
fn tamper_rejects_cloudvault_and_hermes() -> Result<(), Box<dyn Error>> {
    let mut cloudvault = cloudvault_sealed()?;
    cloudvault[12] ^= 1;
    assert!(cloud_vault_aes_gcm_open_combined(cloudvault, KEY.to_vec(), AAD.to_vec()).is_err());

    let mut hermes = hermes_sealed()?;
    hermes[12] ^= 1;
    assert!(hermes_open_combined(hermes, KEY.to_vec(), AAD.to_vec()).is_err());
    Ok(())
}
