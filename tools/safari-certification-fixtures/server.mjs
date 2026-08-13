#!/usr/bin/env node

import { createReadStream } from 'node:fs';
import { open, readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const TOOL_ROOT = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.join(TOOL_ROOT, 'fixtures');
const MANIFEST_PATH = path.join(TOOL_ROOT, 'manifest.json');

export const DEFAULT_HOST = '127.0.0.1';
export const DEFAULT_PORT = 41_771;
export const DEFAULT_CROSS_ORIGIN_PORT = 41_772;

const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);
const CONTENT_TYPES = new Map([
  ['.css', 'text/css; charset=utf-8'],
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.svg', 'image/svg+xml; charset=utf-8']
]);

const STRICT_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
const STANDARD_CSP =
  "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'self'";

export const PRIMARY_ROUTE_DEFINITIONS = Object.freeze({
  '/': { file: 'index.html' },
  '/mixed': { file: 'mixed.html' },
  '/react-controls': { file: 'react-controls.html' },
  '/shadow': { file: 'shadow.html' },
  '/strict-csp': { file: 'strict-csp.html', csp: STRICT_CSP },
  '/infinite-scroll': { file: 'infinite-scroll.html' },
  '/zoom-offset': { file: 'zoom-offset.html' },
  '/frames': {
    file: 'frames.html',
    csp:
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-src 'self' {{SECONDARY_ORIGIN}}; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
  },
  '/frame/same': {
    file: 'frame-same.html',
    csp:
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors {{PRIMARY_ORIGIN}}"
  },
  '/protected/banking': { file: 'protected-banking.html' },
  '/owned-tabs/start': { file: 'owned-tabs-start.html' },
  '/owned-tabs/child': { file: 'owned-tabs-child.html' },
  '/owned-tabs/finish': { file: 'owned-tabs-finish.html' }
});

export const SECONDARY_ROUTE_DEFINITIONS = Object.freeze({
  '/frame/cross': {
    file: 'frame-cross.html',
    csp:
      "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors {{PRIMARY_ORIGIN}}"
  }
});

const STATIC_ROUTE_DEFINITIONS = Object.freeze({
  '/assets/styles.css': { file: 'styles.css' },
  '/assets/mixed-chart.svg': { file: 'mixed-chart.svg' },
  '/assets/mixed-illustration.svg': { file: 'mixed-illustration.svg' },
  '/assets/react.production.min.js': { file: 'vendor/react.production.min.js' },
  '/assets/react-dom.production.min.js': { file: 'vendor/react-dom.production.min.js' },
  '/assets/react-controls.js': { file: 'react-controls.js' },
  '/assets/shadow.js': { file: 'shadow.js' },
  '/assets/strict-csp.js': { file: 'strict-csp.js' },
  '/assets/infinite-scroll.js': { file: 'infinite-scroll.js' },
  '/assets/zoom-offset.js': { file: 'zoom-offset.js' },
  '/assets/frames.js': { file: 'frames.js' },
  '/assets/protected-banking.js': { file: 'protected-banking.js' },
  '/assets/owned-tabs.js': { file: 'owned-tabs.js' }
});

const SECONDARY_STATIC_ROUTE_DEFINITIONS = Object.freeze({
  '/assets/styles.css': STATIC_ROUTE_DEFINITIONS['/assets/styles.css']
});

function parseInteger(value, fallback, label) {
  if (value === undefined) {
    return fallback;
  }
  if (
    typeof value !== 'number' &&
    (typeof value !== 'string' || !/^(?:0|[1-9][0-9]{0,4})$/u.test(value))
  ) {
    throw new Error(`${label} must be an integer from 0 through 65535.`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > 65_535) {
    throw new Error(`${label} must be an integer from 0 through 65535.`);
  }
  return parsed;
}

function isLoopbackHostname(hostname) {
  return LOOPBACK_HOSTNAMES.has(hostname.toLowerCase());
}

function assertLoopbackBindHost(host) {
  const normalized = host.trim().toLowerCase();
  if (!isLoopbackHostname(normalized)) {
    throw new Error(`Refusing non-loopback bind host: ${host}`);
  }
  return normalized === '[::1]' ? '::1' : normalized;
}

function hostHeaderIsLoopback(value) {
  if (!value || /[\s/@\\]/u.test(value)) {
    return false;
  }
  try {
    const parsed = new URL(`http://${value}`);
    return parsed.username === '' && parsed.password === '' && parsed.pathname === '/' && isLoopbackHostname(parsed.hostname);
  } catch {
    return false;
  }
}

function replaceRuntimeTokens(value, runtime) {
  return value
    .replaceAll('{{PRIMARY_ORIGIN}}', runtime.primaryOrigin)
    .replaceAll('{{SECONDARY_ORIGIN}}', runtime.secondaryOrigin);
}

function commonHeaders(contentType, csp = STANDARD_CSP) {
  return {
    'Cache-Control': 'no-store, max-age=0',
    'Content-Security-Policy': csp,
    'Content-Type': contentType,
    'Cross-Origin-Opener-Policy': 'same-origin-allow-popups',
    'Permissions-Policy': 'camera=(), geolocation=(), microphone=(), payment=(), usb=()',
    'Referrer-Policy': 'no-referrer',
    'X-Content-Type-Options': 'nosniff'
  };
}

function writeResponse(response, statusCode, headers, body = '') {
  const bytes = Buffer.isBuffer(body) ? body : Buffer.from(body);
  response.writeHead(statusCode, {
    ...headers,
    'Content-Length': bytes.byteLength
  });
  response.end(bytes);
}

function writeJSON(response, statusCode, value) {
  writeResponse(
    response,
    statusCode,
    commonHeaders('application/json; charset=utf-8', "default-src 'none'; frame-ancestors 'none'"),
    `${JSON.stringify(value, null, 2)}\n`
  );
}

async function renderFile(file, runtime) {
  const absolutePath = path.join(FIXTURE_ROOT, file);
  const extension = path.extname(absolutePath);
  const contentType = CONTENT_TYPES.get(extension);
  if (!contentType) {
    throw new Error(`Unsupported fixture asset type: ${extension}`);
  }
  const handle = await open(absolutePath, 'r');
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile()) {
      throw new Error(`Fixture asset is not a regular file: ${file}`);
    }
    const source = await handle.readFile();
    if (extension === '.html' || extension === '.js' || extension === '.css' || extension === '.svg') {
      return {
        body: Buffer.from(replaceRuntimeTokens(source.toString('utf8'), runtime)),
        contentType
      };
    }
    return { body: source, contentType };
  } finally {
    await handle.close();
  }
}

async function serveDefinition(response, definition, runtime) {
  const asset = await renderFile(definition.file, runtime);
  const csp = replaceRuntimeTokens(definition.csp ?? STANDARD_CSP, runtime);
  writeResponse(response, 200, commonHeaders(asset.contentType, csp), asset.body);
}

function makeRequestHandler(kind, runtime) {
  const definitions = kind === 'primary' ? PRIMARY_ROUTE_DEFINITIONS : SECONDARY_ROUTE_DEFINITIONS;
  return async (request, response) => {
    if (!hostHeaderIsLoopback(request.headers.host)) {
      writeJSON(response, 421, { ok: false, error: 'loopback_host_required' });
      return;
    }

    let url;
    try {
      url = new URL(request.url ?? '/', runtime.originFor(kind));
    } catch {
      writeJSON(response, 400, { ok: false, error: 'invalid_request_url' });
      return;
    }

    if (request.method !== 'GET' && request.method !== 'HEAD') {
      request.resume();
      writeJSON(response, 405, { ok: false, error: 'fixture_is_read_only' });
      return;
    }

    try {
      if (url.pathname === '/healthz') {
        writeJSON(response, 200, {
          ok: true,
          fixtureServer: 'openburnbar-safari-certification',
          originRole: kind
        });
        return;
      }

      if (kind === 'primary' && url.pathname === '/manifest.json') {
        const manifest = JSON.parse(await readFile(MANIFEST_PATH, 'utf8'));
        writeJSON(response, 200, {
          ...manifest,
          runtime: {
            primaryOrigin: runtime.primaryOrigin,
            secondaryOrigin: runtime.secondaryOrigin
          }
        });
        return;
      }

      const staticDefinitions =
        kind === 'primary' ? STATIC_ROUTE_DEFINITIONS : SECONDARY_STATIC_ROUTE_DEFINITIONS;
      const definition = definitions[url.pathname] ?? staticDefinitions[url.pathname];
      if (!definition) {
        writeJSON(response, 404, { ok: false, error: 'fixture_route_not_found' });
        return;
      }
      await serveDefinition(response, definition, runtime);
    } catch (error) {
      writeJSON(response, 500, {
        ok: false,
        error: 'fixture_server_failure',
        message: error instanceof Error ? error.message : 'Unknown fixture server failure.'
      });
    }
  };
}

function listen(server, host, port) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = () => {
      server.off('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function portFor(server) {
  const address = server.address();
  if (!address || typeof address === 'string') {
    throw new Error('Fixture server did not expose an IP socket.');
  }
  return address.port;
}

export async function startFixtureServers(options = {}) {
  const host = assertLoopbackBindHost(options.host ?? DEFAULT_HOST);
  const primaryPort = parseInteger(options.port, DEFAULT_PORT, 'Primary port');
  const secondaryPort = parseInteger(options.crossOriginPort, DEFAULT_CROSS_ORIGIN_PORT, 'Cross-origin port');

  const runtime = {
    primaryOrigin: '',
    secondaryOrigin: '',
    originFor(kind) {
      return kind === 'primary' ? this.primaryOrigin : this.secondaryOrigin;
    }
  };

  const secondary = createServer((request, response) => {
    void makeRequestHandler('secondary', runtime)(request, response);
  });
  const primary = createServer((request, response) => {
    void makeRequestHandler('primary', runtime)(request, response);
  });

  try {
    await listen(secondary, host, secondaryPort);
    runtime.secondaryOrigin = `http://${host === '::1' ? '[::1]' : host}:${portFor(secondary)}`;
    await listen(primary, host, primaryPort);
    runtime.primaryOrigin = `http://${host === '::1' ? '[::1]' : host}:${portFor(primary)}`;
  } catch (error) {
    if (secondary.listening) {
      await close(secondary).catch(() => {});
    }
    if (primary.listening) {
      await close(primary).catch(() => {});
    }
    throw error;
  }

  return {
    host,
    primaryOrigin: runtime.primaryOrigin,
    secondaryOrigin: runtime.secondaryOrigin,
    async close() {
      await Promise.all([close(primary), close(secondary)]);
    }
  };
}

function parseArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (argument === '--host' && value) {
      options.host = value;
      index += 1;
    } else if (argument === '--port' && value) {
      options.port = value;
      index += 1;
    } else if (argument === '--cross-origin-port' && value) {
      options.crossOriginPort = value;
      index += 1;
    } else if (argument === '--help') {
      return { help: true };
    } else {
      throw new Error(`Unknown or incomplete argument: ${argument}`);
    }
  }
  return options;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(
      'Usage: node server.mjs [--host 127.0.0.1] [--port 41771] [--cross-origin-port 41772]\n'
    );
    return;
  }
  const running = await startFixtureServers(options);
  process.stdout.write(
    `${JSON.stringify({
      ready: true,
      primaryOrigin: running.primaryOrigin,
      secondaryOrigin: running.secondaryOrigin
    })}\n`
  );

  let closing = false;
  const shutdown = async () => {
    if (closing) {
      return;
    }
    closing = true;
    await running.close();
  };
  process.once('SIGINT', () => {
    void shutdown().then(() => process.exit(0));
  });
  process.once('SIGTERM', () => {
    void shutdown().then(() => process.exit(0));
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}

export { assertLoopbackBindHost, parseInteger };
