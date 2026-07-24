export const LINUX_RELEASE_PRIVATE_KEY_ENV = 'OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM';

export function withoutLinuxReleasePrivateKey(environment) {
  const sanitized = { ...environment };
  delete sanitized[LINUX_RELEASE_PRIVATE_KEY_ENV];
  return sanitized;
}
