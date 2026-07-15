/// Reviewed ABI contract shared by every public domain-core adapter.
pub const DOMAIN_CORE_ABI_VERSION: u32 = 3;

pub mod cloudvault;
pub mod cloudvault_rewrap;
pub mod cloudvault_search;
pub mod hermes;
pub mod pricing;
pub mod quota;

#[cfg(test)]
mod tests {
    use super::DOMAIN_CORE_ABI_VERSION;

    #[test]
    fn reviewed_domain_core_abi_version_is_current() {
        assert_eq!(DOMAIN_CORE_ABI_VERSION, 3);
    }
}
