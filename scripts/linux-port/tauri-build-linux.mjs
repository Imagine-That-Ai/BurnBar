#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

const forwardedArgs = process.argv.slice(2);

// Production Tauri packages must carry the native Mercury viewer. Keep the
// Cargo feature opt-in for `tauri dev` and direct cargo checks, but make the
// package command fail closed against accidentally shipping the stub viewer.
// The release builder already supplies this flag explicitly; avoid adding a
// duplicate value so both invocation paths produce the same Cargo command.
if (!forwardedArgs.includes('--features')) {
  forwardedArgs.push('--features', 'media-gst');
}

const result = spawnSync('tauri', ['build', ...forwardedArgs], {
  stdio: 'inherit',
  env: process.env
});

if (result.error) {
  console.error(`failed to launch tauri build: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
