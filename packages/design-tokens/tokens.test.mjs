import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const read = (p) => readFileSync(join(HERE, p), "utf8");

// `npm test` runs `node config.mjs` first, so dist/ is fresh here.
const css = read("dist/css/pensieve.css");
const swift = read("dist/swift/PensieveTokens.swift");
const kotlin = read("dist/compose/PensieveTokens.kt");
const winuiXaml = read("dist/winui/PensieveTokens.xaml");
const winuiCs = read("dist/winui/PensieveTokens.cs");

test("CSS exposes the Pensieve + brand tokens as :root custom properties", () => {
  for (const v of [
    "--color-mercury-bright: #f4f6fb",
    "--color-seal-crimson: #c5221f",
    "--color-tier-end-to-end: #3cd6c0",
    "--color-tier-server-readable: #fdc42c",
    "--font-display: Outfit",
    "--space-4: 16px",
    "--radius-pill: 999px",
  ]) {
    assert.ok(css.includes(v), `CSS missing token: ${v}`);
  }
  assert.ok(css.includes(":root"), "CSS must scope to :root");
});

test("Swift + Kotlin emit the same tokens with resolved values (no undefined)", () => {
  assert.ok(!swift.includes("undefined"), "Swift has an unresolved token");
  assert.ok(!kotlin.includes("undefined"), "Kotlin has an unresolved token");
  assert.ok(swift.includes('colorMercuryBright: String = "#f4f6fb"'));
  assert.ok(kotlin.includes('colorMercuryBright: String = "#f4f6fb"'));
  assert.ok(swift.includes("enum PensieveTokens"));
  assert.ok(kotlin.includes("object PensieveTokens"));
});

test("all three platforms emit the same token count (one source of truth)", () => {
  const cssCount = (css.match(/^\s*--[a-z0-9-]+:/gim) || []).length;
  const swiftCount = (swift.match(/static let /g) || []).length;
  const kotlinCount = (kotlin.match(/const val /g) || []).length;
  assert.equal(swiftCount, kotlinCount, "swift vs kotlin token count drift");
  assert.equal(cssCount, swiftCount, "css vs swift token count drift");
  assert.ok(cssCount >= 40, `expected >=40 tokens, got ${cssCount}`);
});

// Android keeps an in-tree copy of the generated Compose tokens (synced by the
// `:app:syncGeneratedSources` Gradle task) because a module can't reference
// files outside itself. CI must catch any drift between that copy and the
// freshly-built dist output, the same way registry.test.mjs guards DataDomains.kt.
test("android in-tree PensieveTokens.kt matches generated Compose output (run ./gradlew :app:syncGeneratedSources)", () => {
  const androidPath = join(
    HERE,
    "..",
    "..",
    "android",
    "app",
    "src",
    "main",
    "java",
    "com",
    "openburnbar",
    "ui",
    "tokens",
    "PensieveTokens.kt"
  );
  const onDisk = readFileSync(androidPath, "utf8");
  assert.equal(
    onDisk,
    kotlin,
    "android PensieveTokens.kt is stale — run ./gradlew :app:syncGeneratedSources (Compose design tokens must equal the generated output byte-for-byte)"
  );
});

test("WinUI XAML emits every color as #AARRGGBB (WinUI cannot parse rgba())", () => {
  // No un-converted CSS rgba() may reach the XAML (WinUI's color parser rejects it).
  assert.ok(!/rgba?\(/i.test(winuiXaml), "XAML still contains an rgba()/rgb() color");
  // rgba(199,207,221,0.06) -> #0FC7CFDD ; rgba(255,255,255,0.08) -> #14FFFFFF (surface).
  assert.ok(winuiXaml.includes('x:Key="PensieveColorMercuryWash">#0FC7CFDD<'), "mercury.wash alpha fold drifted");
  assert.ok(winuiXaml.includes('x:Key="PensieveColorGlassLine">#14FFFFFF<'), "glass.line alpha fold drifted");
  // Opaque #rrggbb gains an explicit #FF alpha; brass.core is the brand accent.
  assert.ok(winuiXaml.includes('x:Key="PensieveColorBrassCore">#FFFA6B06<'), "brass.core opaque alpha missing");
});

test("aurora.tokens.json (macOS Aurora + liquid glass) lands on every platform", () => {
  // CSS custom properties (kebab-case).
  for (const v of [
    "--color-macos-ember: #fa5053",
    "--color-macos-bg: #0d1117",
    "--color-aurora-light-bg: #f3e8e6",
    "--glass-tint-elevated: rgba(31, 38, 48, 0.55)",
    "--glass-stroke-frost: rgba(255, 255, 255, 0.12)",
    "--glass-inner-light: rgba(255, 255, 255, 0.12)",
    "--type-size-body: 14px",
    "--radius-xl: 22px",
  ]) {
    assert.ok(css.includes(v), `CSS missing aurora token: ${v}`);
  }
  // WinUI XAML: alpha folds + type sizes as x:Double + radius convenience shapes.
  assert.ok(winuiXaml.includes('x:Key="PensieveColorMacosEmber">#FFFA5053<'), "macos.ember missing from XAML");
  assert.ok(winuiXaml.includes('x:Key="PensieveGlassTintElevated">#8C1F2630<'), "glass.tint.elevated alpha fold drifted");
  assert.ok(winuiXaml.includes('x:Key="PensieveGlassTintBase">#7A161B22<'), "glass.tint.base alpha fold drifted");
  assert.ok(winuiXaml.includes('x:Key="PensieveGlassSelectionFill">#14FA5053<'), "glass.selection.fill alpha fold drifted");
  assert.ok(winuiXaml.includes('x:Key="PensieveColorAuroraLightEmber">#FFF45B69<'), "auroraLight.ember missing from XAML");
  assert.ok(winuiXaml.includes('x:Key="PensieveTypeSizeBody">14<'), "type.size.body must emit as x:Double");
  assert.ok(winuiXaml.includes('x:Key="PensieveRadiusXlCorner">22<'), "radius.xl must emit a CornerRadius");
  assert.ok(winuiXaml.includes('x:Key="PensieveSpaceXxsThickness">2<'), "space.xxs must emit a Thickness");
  // Swift + C# constants (verbatim rgba strings, same as CSS).
  assert.ok(swift.includes('colorMacosEmber: String = "#fa5053"'), "Swift missing macos.ember");
  assert.ok(swift.includes('glassTintElevated: String = "rgba(31, 38, 48, 0.55)"'), "Swift missing glass.tint.elevated");
  assert.ok(winuiCs.includes('public const string ColorMacosEmber = "#fa5053";'), "C# missing macos.ember");
  // Shell accent now resolves to the macOS Aurora ember (design oracle), not Pensieve brass.
  assert.ok(winuiXaml.includes('x:Key="OBBAccentColor">#FFFA5053<'), "OBBAccentColor must be macOS ember");
  assert.ok(
    winuiXaml.includes('x:Key="OBBMonoFontFamily">ms-appx:///Assets/Fonts/jetbrains-mono.ttf#JetBrains Mono,'),
    "legacy shell mono resources must resolve the bundled JetBrains Mono font",
  );
});

test("Windows brand fonts are packaged and referenced by their ms-appx family URIs", () => {
  const appRoot = join(HERE, "..", "..", "windows", "app", "OpenBurnBar.App");
  const typography = readFileSync(join(appRoot, "Theme", "Typography.xaml"), "utf8");
  const project = readFileSync(join(appRoot, "OpenBurnBar.App.csproj"), "utf8");
  const fonts = [
    ["outfit.ttf", "Outfit"],
    ["geist.ttf", "Geist"],
    ["jetbrains-mono.ttf", "JetBrains Mono"],
    ["fraunces.ttf", "Fraunces"],
  ];

  assert.ok(project.includes('Content Include="Assets\\Fonts\\*.ttf"'), "WinUI project must package the font assets");
  for (const [file, family] of fonts) {
    assert.ok(existsSync(join(appRoot, "Assets", "Fonts", file)), `missing packaged font: ${file}`);
    assert.ok(
      typography.includes(`ms-appx:///Assets/Fonts/${file}#${family}`),
      `Typography.xaml does not bind ${file} to ${family}`,
    );
  }
});

test("WinUI XAML preserves the shell semantic OBB* keys + demonstrates every WinUI type", () => {
  for (const key of [
    "OBBAccentColor", "OBBAccentBrush", "OBBStdoutBrush", "OBBStderrBrush",
    "OBBToolBrush", "OBBSystemBrush", "OBBSurfaceBrush", "OBBStrokeBrush",
    "OBBMonoFontFamily", "OBBCardCornerRadius", "OBBCardPadding",
  ]) {
    assert.ok(winuiXaml.includes(`x:Key="${key}"`), `shell key ${key} missing from generated XAML`);
  }
  // Accent + surface/stroke resolve to Pensieve primitives (brand from the pipeline).
  assert.ok(winuiXaml.includes('x:Key="OBBSurfaceBrush" Color="{StaticResource PensieveColorGlassLine}"'));
  assert.ok(winuiXaml.includes('x:Key="OBBStrokeBrush" Color="{StaticResource PensieveColorGlassLineBright}"'));
  // Every WinUI resource type the emitter must produce is present.
  for (const t of ["<Color ", "<SolidColorBrush ", "<x:Double ", "<Thickness ", "<CornerRadius ", "<x:String "]) {
    assert.ok(winuiXaml.includes(t), `generated XAML never emits ${t.trim()}`);
  }
});

test("WinUI C# mirrors Swift/Kotlin (same token count, PascalCase, no undefined)", () => {
  assert.ok(!winuiCs.includes("undefined"), "C# has an unresolved token");
  assert.ok(winuiCs.includes("public static class PensieveTokens"));
  assert.ok(winuiCs.includes('public const string ColorMercuryBright = "#f4f6fb";'));
  const csCount = (winuiCs.match(/public const string /g) || []).length;
  const swiftCount = (swift.match(/static let /g) || []).length;
  assert.equal(csCount, swiftCount, "C# vs Swift token count drift (one source of truth)");
});

// The WinUI app can't reference files outside its project, so the shell keeps an
// in-tree copy of the generated tokens (same pattern as the Android Compose copy
// above). CI must catch any drift between those copies and fresh dist output.
test("windows shell in-tree Tokens.xaml matches generated WinUI XAML (run node config.mjs && cp)", () => {
  const onDisk = readFileSync(join(HERE, "..", "..", "windows", "app", "OpenBurnBar.App", "Theme", "Tokens.xaml"), "utf8");
  assert.equal(
    onDisk,
    winuiXaml,
    "windows/app/OpenBurnBar.App/Theme/Tokens.xaml is stale — regenerate: (cd packages/design-tokens && node config.mjs) && cp dist/winui/PensieveTokens.xaml ../../windows/app/OpenBurnBar.App/Theme/Tokens.xaml"
  );
});

test("windows shell in-tree PensieveTokens.cs matches generated WinUI C# (run node config.mjs && cp)", () => {
  const onDisk = readFileSync(join(HERE, "..", "..", "windows", "app", "OpenBurnBar.App", "Theme", "PensieveTokens.cs"), "utf8");
  assert.equal(
    onDisk,
    winuiCs,
    "windows/app/OpenBurnBar.App/Theme/PensieveTokens.cs is stale — regenerate: (cd packages/design-tokens && node config.mjs) && cp dist/winui/PensieveTokens.cs ../../windows/app/OpenBurnBar.App/Theme/PensieveTokens.cs"
  );
});

test("encryption-tier colors are distinct (legible tier badges)", () => {
  const e2e = "#3cd6c0";
  const zero = "#8b94a8";
  const server = "#fdc42c";
  assert.notEqual(e2e, zero);
  assert.notEqual(zero, server);
  assert.notEqual(e2e, server);
  for (const c of [e2e, zero, server]) assert.ok(css.includes(c), `tier color ${c} missing from CSS`);
});

// The living-layout motion vocabulary is generated for five platforms, but the
// Swift *expression* layer (MotionTokens.swift, which turns the raw numbers into
// SwiftUI `Animation` values) lives in OpenBurnBarUI, and the generated Swift is
// compiled into the app targets rather than into that package — so it re-declares
// the numbers as literals. This is the gate that keeps the two honest, the same
// way the Android and Windows in-tree copies are gated above.
test("Swift MotionTokens expression layer matches the generated motion tokens", () => {
  const swiftLayer = readFileSync(
    join(HERE, "..", "..", "OpenBurnBarCore", "Sources", "OpenBurnBarUI", "SharedModels", "MotionTokens.swift"),
    "utf8",
  );

  // token leaf name -> [Swift constant, conversion from the generated value]
  const asIs = (v) => v;
  const msToSeconds = (v) => String(Number(v) / 1000);
  const bindings = [
    ["motionSettleResponseMs", "settleResponse", msToSeconds],
    ["motionSettleDamping", "settleDamping", asIs],
    ["motionArriveResponseMs", "arriveResponse", msToSeconds],
    ["motionArriveDamping", "arriveDamping", asIs],
    ["motionArriveRisePx", "arriveRise", asIs],
    ["motionArriveScale", "arriveScale", asIs],
    ["motionDepartMs", "departDuration", msToSeconds],
    ["motionDepartScale", "departScale", asIs],
    ["motionStaggerStepMs", "staggerStep", msToSeconds],
    ["motionStaggerCapMs", "staggerCap", msToSeconds],
    ["motionTickMs", "tickDuration", msToSeconds],
    ["motionPulsePeriodMs", "pulsePeriod", msToSeconds],
    ["motionPulseFloor", "pulseFloor", asIs],
    ["motionReducedMs", "reducedDuration", msToSeconds],
  ];

  for (const [tokenName, swiftName, convert] of bindings) {
    const emitted = swift.match(new RegExp(`${tokenName}: String = "([^"]+)"`));
    assert.ok(emitted, `generated Swift is missing ${tokenName}`);
    const expected = Number(convert(emitted[1]));

    const declared = swiftLayer.match(new RegExp(`static let ${swiftName}: Double = ([0-9.]+)`));
    assert.ok(declared, `MotionTokens.swift is missing 'static let ${swiftName}: Double'`);
    assert.equal(
      Number(declared[1]),
      expected,
      `MotionTokens.${swiftName} (${declared[1]}) drifted from motion.${tokenName} (${emitted[1]})`,
    );
  }
});
