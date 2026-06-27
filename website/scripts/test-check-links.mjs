#!/usr/bin/env node

import assert from "node:assert/strict";

import { isExecutableHrefScheme } from "./check-links.mjs";

assert.equal(isExecutableHrefScheme("javascript:alert(1)"), true);
assert.equal(isExecutableHrefScheme(" JaVaScRiPt:alert(1)"), true);
assert.equal(isExecutableHrefScheme("\tvbscript:msgbox(1)"), true);
assert.equal(isExecutableHrefScheme("data:text/html,<script>alert(1)</script>"), true);
assert.equal(isExecutableHrefScheme("https://burnbar.ai/router"), false);
assert.equal(isExecutableHrefScheme("/router#sources"), false);
assert.equal(isExecutableHrefScheme("mailto:security@burnbar.ai"), false);

console.log("PASS: link checker blocks executable href schemes");
