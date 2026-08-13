import { access, readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const manifestPath = resolve('dist/manifest.json');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
const failures = [];

if (manifest.manifest_version !== 3) {
  failures.push('manifest_version must be 3');
}
if (manifest.background?.service_worker !== 'background.js') {
  failures.push('background.service_worker must point to background.js');
}
if (manifest.browser_specific_settings?.safari?.strict_min_version !== '15.4') {
  failures.push('Safari strict_min_version must be 15.4');
}
if (!manifest.permissions?.includes('nativeMessaging')) {
  failures.push('nativeMessaging permission is required');
}
const allowedPersistentHosts = new Set(['http://127.0.0.1/*', 'http://localhost/*', 'http://[::1]/*']);
const persistentHosts = manifest.host_permissions ?? [];
const persistentHostSet = new Set(persistentHosts);
if (
  !Array.isArray(persistentHosts) ||
  persistentHosts.some((pattern) => !allowedPersistentHosts.has(pattern)) ||
  persistentHosts.length !== allowedPersistentHosts.size ||
  persistentHostSet.size !== allowedPersistentHosts.size ||
  [...allowedPersistentHosts].some((pattern) => !persistentHostSet.has(pattern))
) {
  failures.push('host_permissions must contain only the three loopback gateway patterns');
}
if (manifest.safari) {
  failures.push('Safari configuration belongs under browser_specific_settings.safari');
}

const referencedFiles = [
  manifest.background?.service_worker,
  manifest.action?.default_popup,
  manifest.action?.default_icon?.['128'],
  ...(manifest.web_accessible_resources?.flatMap((entry) => entry.resources ?? []) ?? [])
].filter((value) => typeof value === 'string');

for (const file of referencedFiles) {
  try {
    await access(resolve('dist', file));
  } catch {
    failures.push(`manifest references missing file: ${file}`);
  }
}

if (failures.length > 0) {
  throw new Error(`Safari manifest validation failed:\n- ${failures.join('\n- ')}`);
}

process.stdout.write(`Validated ${manifestPath} (${referencedFiles.length} referenced files).\n`);
