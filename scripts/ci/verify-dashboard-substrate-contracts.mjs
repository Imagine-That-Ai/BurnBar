#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../..', import.meta.url);
const failures = [];

function source(relativePath) {
  return readFileSync(join(root.pathname, relativePath), 'utf8');
}

function expectContains(relativePath, needle, note) {
  const text = source(relativePath);
  if (!text.includes(needle)) {
    failures.push(`${relativePath}: missing ${JSON.stringify(needle)}${note ? ` (${note})` : ''}`);
  }
}

function expectCountAtLeast(relativePath, needle, minimum, note) {
  const text = source(relativePath);
  const count = text.split(needle).length - 1;
  if (count < minimum) {
    failures.push(
      `${relativePath}: expected at least ${minimum} occurrences of ${JSON.stringify(needle)}, found ${count}` +
        `${note ? ` (${note})` : ''}`
    );
  }
}

const conceptLayouts = [
  'AgentLens/Views/Dashboard/Layouts/AtelierLayoutView.swift',
  'AgentLens/Views/Dashboard/Layouts/AuroraLayoutView.swift',
  'AgentLens/Views/Dashboard/Layouts/NebulaLayoutView.swift',
  'AgentLens/Views/Dashboard/Layouts/ConstellationLayoutView.swift',
  'AgentLens/Views/Dashboard/Layouts/CockpitLayoutView.swift',
];

for (const layout of conceptLayouts) {
  expectContains(layout, 'conceptUpdateBanner', 'concept layouts must keep the update banner visible');
}

const conceptComponents = 'AgentLens/Views/Dashboard/Layouts/DashboardConceptComponents.swift';
for (const needle of [
  'conceptCurveCard.frame',
  'CastleGreatHallContainer()',
  'NarrativeCardView(dataStore: dataStore)',
  'providerLane',
  'modelLane',
  'activityLane',
]) {
  expectContains(conceptComponents, needle, 'concept details drawer must keep Classic-only sections reachable');
}

const dashboardBackdrop = 'AgentLens/Views/Dashboard/Components/DashboardToolbarAndBackdrop.swift';
expectContains(dashboardBackdrop, 'kernelSubstrateOverlay', 'kernel backdrop must retain substrate overlay plumbing');
expectContains(dashboardBackdrop, 'if substrateEnabled', 'kernel substrate overlay must honor the substrate toggle');
expectContains(dashboardBackdrop, 'substrate: substrate', 'dashboard swarm hosts must receive the selected substrate');

for (const relativePath of [
  'AgentLens/Views/Dashboard/Components/ConstellationBackgroundView.swift',
  'AgentLens/App/AppDelegate.swift',
  'AgentLens/Views/Settings/AppearancePreviewCard.swift',
]) {
  expectContains(relativePath, '@StateObject private var substrateBox = SwarmSubstrateBox()');
  expectContains(relativePath, 'substrate: substrate');
}

expectContains(
  'AgentLens/App/AppDelegate.swift',
  'struct SwarmWallpaperView: View',
  'desktop wallpaper preview is a non-dashboard swarm host'
);

expectContains(
  'OpenBurnBarMobile/Views/Aurora/WebsiteBackgroundView.swift',
  '@StateObject private var substrateBox = SwarmSubstrateBox()'
);
expectCountAtLeast(
  'OpenBurnBarMobile/Views/Aurora/WebsiteBackgroundView.swift',
  'substrate: substrate',
  2,
  'editorial and live mobile swarm backgrounds both need substrates'
);

for (const relativePath of [
  'OpenBurnBarMobile/Views/Aurora/ConstellationBackgroundView.swift',
  'OpenBurnBarMobile/Views/Aurora/WallpaperGeneratorView.swift',
]) {
  expectContains(relativePath, '@StateObject private var substrateBox = SwarmSubstrateBox()');
  expectContains(relativePath, 'substrate: substrate');
}

expectCountAtLeast(
  'OpenBurnBarMobile/Views/Aurora/WallpaperGeneratorView.swift',
  'substrate: substrate',
  2,
  'mobile wallpaper preview and export swarm hosts both need substrates'
);

if (failures.length > 0) {
  console.error('FAIL: dashboard substrate contract drift detected');
  for (const failure of failures) {
    console.error(`- ${failure}`);
  }
  process.exit(1);
}

console.log('PASS: dashboard substrate contracts keep review-critical surfaces wired.');
