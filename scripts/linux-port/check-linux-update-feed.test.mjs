import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyFeedResponse, finalizeFeedReport, looksLikeHtml, validateFeedDocument } from './lib/linux-update-feed.mjs';

function validFeed() {
  const artifact = (type, architecture) => ({
    type,
    architecture,
    url: `https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/app-${type}-${architecture}`,
    sha256: 'a'.repeat(64),
    size: 100,
    signatureUrl: `https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/app-${type}-${architecture}.sig`
  });
  return {
    schemaVersion: 1,
    product: 'OpenBurnBar',
    platform: 'linux',
    version: '1.2.3',
    gitCommit: 'b'.repeat(40),
    publishedAt: '2026-07-09T00:00:00Z',
    channel: 'prerelease',
    artifacts: [artifact('appimage', 'aarch64'), artifact('appimage', 'x86_64')],
    signature: {
      algorithm: 'Ed25519',
      publicKeySpkiSha256: 'c'.repeat(64),
      url: 'https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/latest-linux.json.ed25519.sig'
    }
  };
}

test('HTML hard-fails even with allow-missing', () => {
  assert.equal(looksLikeHtml('{}', 'text/html; charset=utf-8'), true);
  const result = classifyFeedResponse({ status: 200, contentType: 'text/html', text: '<!doctype html>', allowMissing: true });
  assert.equal(result.passed, false);
  assert.equal(result.bodyKind, 'html');
});

test('strict valid JSON feed passes schema classification', () => {
  const feed = validFeed();
  const result = classifyFeedResponse({ status: 200, contentType: 'application/json; charset=utf-8', text: JSON.stringify(feed) });
  assert.equal(result.passed, true);
  assert.deepEqual(result.document, feed);
});

test('wrong MIME fails even when body is valid JSON', () => {
  const result = classifyFeedResponse({ status: 200, contentType: 'text/plain', text: JSON.stringify(validFeed()) });
  assert.equal(result.passed, false);
  assert.equal(result.bodyKind, 'wrong-mime');
});

test('empty object and legacy weak fixture fail schema', () => {
  for (const document of [{}, { version: '0.1.0', url: 'https://github.com/app.AppImage' }]) {
    const result = classifyFeedResponse({ status: 200, contentType: 'application/json', text: JSON.stringify(document) });
    assert.equal(result.passed, false);
    assert.ok(result.failures.length > 5);
  }
});

test('invalid architecture, sha, URL, duplicate, and missing x86 AppImage fail', () => {
  const feed = validFeed();
  feed.artifacts[0].architecture = 'mips';
  feed.artifacts[0].sha256 = 'bad';
  feed.artifacts[0].url = 'http://localhost/app';
  feed.artifacts[1] = { ...feed.artifacts[0] };
  const failures = validateFeedDocument(feed);
  assert.ok(failures.some((failure) => /architecture is invalid/.test(failure)));
  assert.ok(failures.some((failure) => /SHA-256 is invalid/.test(failure)));
  assert.ok(failures.some((failure) => /not allowlisted HTTPS/.test(failure)));
  assert.ok(failures.some((failure) => /duplicate/.test(failure)));
  assert.ok(failures.some((failure) => /missing AppImage architecture/.test(failure)));
});

test('replayed or non-monotonic version fails', () => {
  assert.ok(validateFeedDocument(validFeed(), { previousVersion: '1.2.3' }).some((failure) => /not monotonic/.test(failure)));
  assert.ok(validateFeedDocument(validFeed(), { previousVersion: '2.0.0' }).some((failure) => /not monotonic/.test(failure)));
});

test('JSON array and non-JSON bodies fail', () => {
  assert.equal(classifyFeedResponse({ status: 200, contentType: 'application/json', text: '[]' }).passed, false);
  assert.equal(classifyFeedResponse({ status: 200, contentType: 'application/json', text: 'nope' }).passed, false);
});

test('404 is soft only with allow-missing; other HTTP errors fail', () => {
  assert.equal(classifyFeedResponse({ status: 404, contentType: 'text/plain', text: '', allowMissing: true }).passed, true);
  assert.equal(classifyFeedResponse({ status: 404, contentType: 'text/plain', text: '', allowMissing: false }).passed, false);
  assert.equal(classifyFeedResponse({ status: 500, contentType: 'text/plain', text: '', allowMissing: true }).passed, false);
});

test('finalize report passes only without failures', () => {
  assert.equal(finalizeFeedReport({ failures: [] }).passed, true);
  assert.equal(finalizeFeedReport({ failures: ['x'] }).passed, false);
});
