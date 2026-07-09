import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyFeedResponse, finalizeFeedReport, looksLikeHtml } from './lib/linux-update-feed.mjs';

test('looksLikeHtml: content-type text/html', () => {
  assert.equal(looksLikeHtml('{}', 'text/html; charset=utf-8'), true);
});

test('looksLikeHtml: body doctype', () => {
  assert.equal(looksLikeHtml('<!DOCTYPE html><html></html>', 'application/json'), true);
});

test('looksLikeHtml: plain json', () => {
  assert.equal(looksLikeHtml('{"version":"1"}', 'application/json'), false);
});

test('classify: HTML hard-fails even with allow-missing', () => {
  const r = classifyFeedResponse({
    status: 200,
    contentType: 'text/html',
    text: '<!doctype html><html><body>OpenBurnBar</body></html>',
    allowMissing: true
  });
  assert.equal(r.bodyKind, 'html');
  assert.equal(r.passed, false);
  assert.ok(r.failures.some((f) => /HTML/i.test(f)));
});

test('classify: valid JSON object passes', () => {
  const r = classifyFeedResponse({
    status: 200,
    contentType: 'application/json',
    text: '{"version":"0.1.0","url":"https://example.com/app.AppImage"}',
    allowMissing: false
  });
  assert.equal(r.bodyKind, 'json');
  assert.equal(r.passed, true);
  assert.deepEqual(r.keys, ['version', 'url']);
});

test('classify: JSON array fails', () => {
  const r = classifyFeedResponse({
    status: 200,
    contentType: 'application/json',
    text: '[]',
    allowMissing: false
  });
  assert.equal(r.bodyKind, 'json-non-object');
  assert.equal(r.passed, false);
});

test('classify: 404 allow-missing soft pass', () => {
  const r = classifyFeedResponse({
    status: 404,
    contentType: 'text/plain',
    text: 'not found',
    allowMissing: true
  });
  assert.equal(r.bodyKind, 'missing');
  assert.equal(r.passed, true);
  assert.ok(r.warnings.length > 0);
});

test('classify: 404 without allow-missing fails', () => {
  const r = classifyFeedResponse({
    status: 404,
    contentType: 'text/plain',
    text: 'not found',
    allowMissing: false
  });
  assert.equal(r.passed, false);
});

test('classify: non-json body fails', () => {
  const r = classifyFeedResponse({
    status: 200,
    contentType: 'text/plain',
    text: 'not-json',
    allowMissing: false
  });
  assert.equal(r.bodyKind, 'non-json');
  assert.equal(r.passed, false);
});

test('finalizeFeedReport: passed iff no failures', () => {
  assert.equal(finalizeFeedReport({ failures: [] }).passed, true);
  assert.equal(finalizeFeedReport({ failures: ['x'] }).passed, false);
});

test('classify: HTTP 500 fails', () => {
  const r = classifyFeedResponse({
    status: 500,
    contentType: 'text/plain',
    text: 'error',
    allowMissing: true
  });
  assert.equal(r.bodyKind, 'http-error');
  assert.equal(r.passed, false);
});

test('classify: application/xhtml+xml is HTML', () => {
  assert.equal(looksLikeHtml('<html/>', 'application/xhtml+xml'), true);
  const r = classifyFeedResponse({
    status: 200,
    contentType: 'application/xhtml+xml',
    text: '<html><body>x</body></html>',
    allowMissing: true
  });
  assert.equal(r.bodyKind, 'html');
  assert.equal(r.passed, false);
});
