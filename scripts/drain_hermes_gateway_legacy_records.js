#!/usr/bin/env node
"use strict";

const { main } = require("./ci/drain_hermes_gateway_legacy_records.js");

main(process.argv.slice(2)).catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
});
