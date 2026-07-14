#!/usr/bin/env node
import { buildLinuxCloudAuthConfig } from './lib/linux-package-payload.mjs';

// Keep this gate deliberately side-effect free: release jobs should reject bad
// repository variables before starting Docker, Swift, Rust, or Tauri work.
try {
  const config = buildLinuxCloudAuthConfig({
    env: process.env,
    requireConfigured: true
  });
  console.log(`Linux public release configuration validated (${Object.keys(config).length - 2} identifiers).`);
} catch (error) {
  console.error(`validate-linux-release-public-config: ${error.message}`);
  process.exit(1);
}
