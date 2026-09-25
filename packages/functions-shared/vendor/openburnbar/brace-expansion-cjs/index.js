"use strict";

// Callable CommonJS facade over the patched brace-expansion algorithm.
//
// minimatch 3 (pinned for the Firebase CLI 15.x runtime contract) loads brace
// expansion as `var expand = require("brace-expansion")` and calls it
// directly. Every release patched against the expansion DoS advisories
// (GHSA-mh99-v99m-4gvg, GHSA-3jxr-9vmj-r5cp) exports a named-only surface
// (`{ expand }`), which crashes those consumers at brace-expansion call time.
//
// This shim restores the callable default export on top of
// @isaacs/brace-expansion (the maintained fork of the same algorithm, patched
// against the same DoS class in >= 5.0.1). The fork's distinct package name is
// load-bearing: a dependency literally named "brace-expansion" would be
// rewritten again by the npm overrides that route minimatch 3 consumers here.
const { expand } = require("@isaacs/brace-expansion");

module.exports = expand;
module.exports.expand = expand;
