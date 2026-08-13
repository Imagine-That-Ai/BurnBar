import assert from 'node:assert/strict';
import test from 'node:test';

import { verifySourceSafety } from './verify.mjs';

function findingsFor(relative, source) {
  const findings = [];
  verifySourceSafety(relative, source, findings);
  return findings;
}

test('source safety accepts local-only fixture patterns', () => {
  assert.deepEqual(
    findingsFor(
      'safe.html',
      '<link rel="stylesheet" href="/assets/styles.css"><script src="/assets/app.js"></script>'
    ),
    []
  );
  assert.deepEqual(
    findingsFor(
      'safe.js',
      "const frame = document.createElement('iframe'); frame.src = '{{SECONDARY_ORIGIN}}/frame/cross'; window.open('/owned-tabs/child');"
    ),
    []
  );
  assert.deepEqual(
    findingsFor(
      'safe-actions.js',
      "location.assign('/next'); form.action = '/submit'; link.setAttribute('href', '/details');"
    ),
    []
  );
  assert.deepEqual(findingsFor('safe.css', 'main { background-image: url("/assets/pattern.svg"); }'), []);
});

test('source safety rejects external HTML resources, actions, and meta refreshes', () => {
  for (const source of [
    '<img src="https://example.invalid/a.png">',
    '<form action="//example.invalid/submit"></form>',
    '<meta http-equiv="refresh" content="0; url=https://example.invalid/">'
  ]) {
    assert.ok(findingsFor('unsafe.html', source).length > 0, source);
  }
});

test('source safety scopes benign namespace and documentation literals to exact required files', () => {
  assert.deepEqual(
    findingsFor('mixed-chart.svg', '<svg xmlns="http://www.w3.org/2000/svg"></svg>'),
    []
  );
  assert.ok(
    findingsFor('unexpected.js', "const docs = 'https://reactjs.org/docs/error-decoder.html?invariant='")
      .length > 0
  );
  assert.ok(
    findingsFor('unexpected.svg', '<svg xmlns="http://www.w3.org/2000/svg"></svg>').length > 0
  );
});

test('source safety rejects external CSS imports and URLs', () => {
  for (const source of [
    '@import "https://example.invalid/a.css";',
    'main { background: url(//example.invalid/a.png); }'
  ]) {
    assert.ok(findingsFor('unsafe.css', source).length > 0, source);
  }
});

test('source safety rejects request, navigation, and dynamic URL assignment primitives', () => {
  for (const source of [
    "fetch('https://example.invalid/data')",
    "new WebSocket('wss://example.invalid/socket')",
    "window.open('https://example.invalid/', '_blank')",
    "location.href = 'https://example.invalid/'",
    "document.location.replace('//example.invalid/')",
    "image.src = 'https://example.invalid/a.png'",
    "link.setAttribute('href', '//example.invalid/a.css')",
    "const endpoint = 'https://example.invalid/data'"
  ]) {
    assert.ok(findingsFor('unsafe.js', source).length > 0, source);
  }
});

test('source safety applies network enforcement to both executable vendor filenames', () => {
  for (const [relative, source] of [
    ['vendor/react.production.min.js', "fetch('https://example.invalid/data')"],
    [
      'vendor/react-dom.production.min.js',
      "navigator.sendBeacon('https://example.invalid/a', 'x')"
    ]
  ]) {
    const findings = findingsFor(relative, source);
    assert.ok(findings.some((finding) => finding.includes('pinned upstream runtime SHA-256')));
    assert.ok(findings.some((finding) => finding.includes('network-request primitive')));
  }
});

test('source safety rejects every computed navigation destination', () => {
  const computed = "protocol + ':' + '/' + '/' + 'example.invalid/'";
  for (const source of [
    `window.open(${computed})`,
    `location = ${computed}`,
    `location.href = ${computed}`,
    `document.location.assign(${computed})`,
    `window.location.replace(${computed})`
  ]) {
    assert.ok(
      findingsFor('computed-navigation.js', `const protocol = 'https'; ${source}`).length > 0,
      source
    );
  }
});

test('source safety rejects every computed resource and action destination', () => {
  const computed = "protocol + ':' + '/' + '/' + 'example.invalid/a'";
  for (const source of [
    `image.src = ${computed}`,
    `link.href = ${computed}`,
    `form.action = ${computed}`,
    `button.formAction = ${computed}`,
    `node.setAttribute('src', ${computed})`,
    `node.setAttribute('href', ${computed})`,
    `node.setAttribute('action', ${computed})`,
    `node.setAttribute('formaction', ${computed})`
  ]) {
    assert.ok(
      findingsFor('computed-resource.js', `const protocol = 'https'; ${source}`).length > 0,
      source
    );
  }
});
