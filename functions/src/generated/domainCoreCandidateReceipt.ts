/**
 * Build-bundled domain-core authority. Signed pipelines replace the compiled
 * counterpart before artifact verification; source builds default to development.
 */
export const DOMAIN_CORE_CANDIDATE_RECEIPT = Object.freeze({
  schemaVersion: 1,
  name: "developer",
  artifactAuthority: "development",
  distribution: "development",
  rolloutChannel: null,
  evidenceEnabled: false,
  candidateIdentity: null,
  modes: Object.freeze({
    quota: "legacy",
    cloudVault: "legacy",
    cloudVaultRewrap: "legacy",
    cloudVaultSearch: "legacy",
    hermes: "legacy",
    pricing: "legacy",
  }),
});
