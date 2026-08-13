import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { build } from 'esbuild';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const extensionRoot = resolve(scriptDirectory, '..');
const repositoryRoot = resolve(extensionRoot, '..', '..');
const outputDirectory = resolve(extensionRoot, 'dist');
const bundleDefaults = {
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['safari15.4'],
  sourcemap: false,
  legalComments: 'none',
  minify: true
};

await rm(outputDirectory, { recursive: true, force: true });
await mkdir(resolve(outputDirectory, 'icons'), { recursive: true });
await mkdir(resolve(outputDirectory, 'providers'), { recursive: true });

await Promise.all([
  build({
    ...bundleDefaults,
    entryPoints: [resolve(extensionRoot, 'src/background/index.ts')],
    outfile: resolve(outputDirectory, 'background.js')
  }),
  build({
    ...bundleDefaults,
    entryPoints: [resolve(extensionRoot, 'src/content/index.ts')],
    outfile: resolve(outputDirectory, 'content.js')
  }),
  build({
    ...bundleDefaults,
    entryPoints: [resolve(extensionRoot, 'src/popup/index.ts')],
    outfile: resolve(outputDirectory, 'popup.js')
  })
]);

const manifest = JSON.parse(await readFile(resolve(extensionRoot, 'manifest.json'), 'utf8'));
const packageMetadata = JSON.parse(await readFile(resolve(extensionRoot, 'package.json'), 'utf8'));
manifest.version = packageMetadata.version;

await Promise.all([
  writeFile(resolve(outputDirectory, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`),
  cp(resolve(extensionRoot, 'src/popup/index.html'), resolve(outputDirectory, 'popup.html')),
  cp(resolve(extensionRoot, 'src/popup/popup.css'), resolve(outputDirectory, 'popup.css')),
  cp(resolve(extensionRoot, 'src/content/pageWorldRunner.js'), resolve(outputDirectory, 'page-world-runner.js')),
  cp(resolve(repositoryRoot, 'packages/design-tokens/dist/css/pensieve.css'), resolve(outputDirectory, 'pensieve.css')),
  cp(
    resolve(repositoryRoot, 'extensions/openburnbar/media/app-icon-128.png'),
    resolve(outputDirectory, 'icons/app-icon-128.png')
  ),
  cp(
    resolve(repositoryRoot, 'AgentLens/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.svg'),
    resolve(outputDirectory, 'icons/app-logo.svg')
  ),
  cp(resolve(extensionRoot, 'src/popup/providers'), resolve(outputDirectory, 'providers'), { recursive: true })
]);
