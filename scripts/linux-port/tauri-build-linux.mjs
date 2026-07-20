#!/usr/bin/env node
import { spawnSync } from 'node:child_process';

export function ensureMediaGstreamerFeature(args) {
  const forwardedArgs = [...args];
  const featureValues = [];

  for (let index = 0; index < forwardedArgs.length; index += 1) {
    const argument = forwardedArgs[index];
    if (argument === '--features') {
      const value = forwardedArgs[index + 1];
      if (value && !value.startsWith('-')) {
        featureValues.push({ index: index + 1, value, inline: false });
        index += 1;
      } else {
        featureValues.push({ index: index + 1, value: '', inline: false });
      }
    } else if (argument.startsWith('--features=')) {
      featureValues.push({
        index,
        value: argument.slice('--features='.length),
        inline: true
      });
    }
  }

  const hasMediaFeature = featureValues.some(({ value }) =>
    value.split(',').map((feature) => feature.trim()).includes('media-gst')
  );
  if (hasMediaFeature) return forwardedArgs;

  if (featureValues.length === 0) {
    forwardedArgs.push('--features', 'media-gst');
    return forwardedArgs;
  }

  const first = featureValues[0];
  if (first.inline) {
    forwardedArgs[first.index] = first.value
      ? `--features=${first.value},media-gst`
      : '--features=media-gst';
  } else if (first.value) {
    forwardedArgs[first.index] = `${first.value},media-gst`;
  } else {
    forwardedArgs.splice(first.index, 0, 'media-gst');
  }
  return forwardedArgs;
}

const forwardedArgs = ensureMediaGstreamerFeature(process.argv.slice(2));

// Production Tauri packages must carry the native Mercury viewer. Keep the
// Cargo feature opt-in for `tauri dev` and direct cargo checks, but make the
// package command fail closed against accidentally shipping the stub viewer.
// The release builder already supplies this flag explicitly; avoid adding a
// duplicate value so both invocation paths produce the same Cargo command.
const result = spawnSync('tauri', ['build', ...forwardedArgs], {
  stdio: 'inherit',
  env: process.env
});

if (result.error) {
  console.error(`failed to launch tauri build: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
