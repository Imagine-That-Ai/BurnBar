#!/usr/bin/env node
import { createRequire } from "node:module";
import fs from "node:fs/promises";
import path from "node:path";
import { realpathSync } from "node:fs";
import process from "node:process";
import { fileURLToPath, pathToFileURL } from "node:url";

const SCANNER_VERSION = 1;
const CODE_EXTENSIONS = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".swift", ".kt", ".kts"]);
const TYPESCRIPT_EXTENSIONS = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]);
const SWIFT_EXTENSIONS = new Set([".swift"]);
const KOTLIN_EXTENSIONS = new Set([".kt", ".kts"]);
const GENERATED_FILE_PATTERNS = [/\.generated\.(swift|ts|tsx|js|jsx|kt|kts)$/i, /Generated\.(swift|ts|tsx|js|jsx|kt|kts)$/i];
const EXCLUDED_SEGMENTS = new Set([".build", ".derived-data", ".git", ".next", ".turbo", ".venv", ".vscode-test", "Carthage", "DerivedData", "Generated", "Pods", "build", "coverage", "dist", "lib", "node_modules", "uniffi"]);
const EXCLUDED_PREFIXES = [
  ".firebase/",
  ".swiftpm/",
  "Vendor/",
  "artifacts/",
  "functions/src/types/generated/",
  "OpenBurnBarMobile/Resources/Mermaid/",
  "tools/type-debt/fixtures/",
];
const DEFAULT_SCAN_ROOTS = [
  "functions/src",
  "extensions",
  "services",
  "website/src",
  "AgentLens",
  "AgentLensTests/Active",
  "OpenBurnBarCore/Sources",
  "OpenBurnBarCore/Tests",
  "OpenBurnBarDaemon/Sources",
  "OpenBurnBarDaemon/Tests",
  "OpenBurnBarMobile",
  "OpenBurnBarMobileTests",
  "android/app/src/main",
  "android/app/src/test",
  "android/openburnbar-iroh-relay/src/main/java/com",
];

export function isExcludedPath(relativePath) {
  const normalized = normalizePath(relativePath);
  if (!normalized || normalized === ".") return false;
  if (EXCLUDED_PREFIXES.some((prefix) => normalized.startsWith(prefix))) return true;
  const segments = normalized.split("/");
  if (segments.some((segment) => EXCLUDED_SEGMENTS.has(segment))) return true;
  return GENERATED_FILE_PATTERNS.some((pattern) => pattern.test(path.basename(normalized)));
}

export async function auditUnsafeCasts(options = {}) {
  const repoRoot = path.resolve(options.repoRoot ?? process.cwd());
  const tsParser = options.tsParser === undefined ? await loadTypeScriptParser(repoRoot) : options.tsParser;
  const violations = [];
  const scanRoots = await resolveScanRoots(repoRoot, options.scanRoots ?? DEFAULT_SCAN_ROOTS);
  for (const scanRoot of scanRoots) {
  for await (const filePath of walkCodeFiles(repoRoot, scanRoot)) {
    const relativePath = normalizePath(path.relative(repoRoot, filePath));
    const source = await fs.readFile(filePath, "utf8");
    const ext = path.extname(filePath);
    if (TYPESCRIPT_EXTENSIONS.has(ext)) violations.push(...scanTypeScript(source, relativePath, tsParser));
    else if (SWIFT_EXTENSIONS.has(ext)) violations.push(...scanSwift(source, relativePath));
    else if (KOTLIN_EXTENSIONS.has(ext)) violations.push(...scanKotlin(source, relativePath));
  }
  }
  violations.sort(compareViolations);
  return buildReport(violations, { tsMode: tsParser ? "typescript-eslint-parser" : "token-fallback" });
}

async function resolveScanRoots(repoRoot, roots) {
  const resolved = [];
  for (const root of roots) {
    const fullPath = path.resolve(repoRoot, root);
    try {
      const stat = await fs.stat(fullPath);
      if (stat.isDirectory()) resolved.push(fullPath);
    } catch {}
  }
  return resolved.length > 0 ? resolved : [repoRoot];
}

async function* walkCodeFiles(repoRoot, directory, seen = new Set()) {
  let realDirectory;
  try {
    realDirectory = await fs.realpath(directory);
  } catch {
    return;
  }
  if (seen.has(realDirectory)) return;
  seen.add(realDirectory);

  const entries = await fs.readdir(directory, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    const fullPath = path.join(directory, entry.name);
    const relativePath = normalizePath(path.relative(repoRoot, fullPath));
    if (isExcludedPath(relativePath)) continue;
    if (entry.isDirectory()) yield* walkCodeFiles(repoRoot, fullPath, seen);
    else if (entry.isFile() && CODE_EXTENSIONS.has(path.extname(entry.name))) yield fullPath;
  }
}

async function loadTypeScriptParser(repoRoot) {
  const candidates = [path.join(repoRoot, "functions", "package.json"), path.join(repoRoot, "extensions", "openburnbar", "package.json"), path.join(repoRoot, "package.json")];
  for (const candidate of candidates) {
    try {
      await fs.access(candidate);
      const requireFromPackage = createRequire(pathToFileURL(candidate));
      const parser = requireFromPackage("@typescript-eslint/parser");
      if (parser?.parse || parser?.parseForESLint) return parser;
    } catch {}
  }
  return null;
}

function scanTypeScript(source, filePath, parser) {
  if (parser) {
    try { return scanTypeScriptAst(source, filePath, parser); }
    catch (error) { return scanTypeScriptTokens(source, filePath, `AST parse failed: ${error.message}`); }
  }
  return scanTypeScriptTokens(source, filePath, "TypeScript parser unavailable");
}

function scanTypeScriptAst(source, filePath, parser) {
  const ast = parser.parse(source, { comment: false, ecmaFeatures: { jsx: filePath.endsWith(".tsx") || filePath.endsWith(".jsx") }, ecmaVersion: "latest", errorOnUnknownASTType: false, loc: true, range: true, sourceType: "module", tokens: false });
  const violations = [];
  traverseAst(ast, (node) => {
    if (node.type === "TSAsExpression") {
      if (isConstAssertion(node.typeAnnotation)) return;
      violations.push(violationFromRange({ source, filePath, node, language: "typescript", kind: isAnyType(node.typeAnnotation) ? "ts_as_any" : "ts_type_assertion", detail: typeAnnotationText(source, node.typeAnnotation) }));
    } else if (node.type === "TSTypeAssertion") {
      violations.push(violationFromRange({ source, filePath, node, language: "typescript", kind: "ts_type_assertion", detail: typeAnnotationText(source, node.typeAnnotation) }));
    } else if (node.type === "TSNonNullExpression") {
      violations.push(violationFromRange({ source, filePath, node, language: "typescript", kind: "ts_non_null_assertion", detail: "non-null assertion" }));
    }
  });
  return violations;
}

function traverseAst(node, visit) {
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const [key, value] of Object.entries(node)) {
    if (key === "parent" || key === "loc" || key === "range" || key === "tokens" || key === "comments") continue;
    if (Array.isArray(value)) for (const child of value) traverseAst(child, visit);
    else if (value && typeof value === "object" && typeof value.type === "string") traverseAst(value, visit);
  }
}

function isConstAssertion(typeAnnotation) {
  if (!typeAnnotation) return false;
  if (typeAnnotation.type === "TSConstKeyword") return true;
  const typeName = typeAnnotation.typeName;
  return typeAnnotation.type === "TSTypeReference" && typeName?.type === "Identifier" && typeName.name === "const";
}
function isAnyType(typeAnnotation) { return typeAnnotation?.type === "TSAnyKeyword"; }
function typeAnnotationText(source, node) { return node?.range ? source.slice(node.range[0], node.range[1]).trim() : ""; }

function scanTypeScriptTokens(source, filePath, reason) {
  const scrubbed = stripCommentsAndStrings(source);
  const violations = [];
  const asPattern = /\bas\s+([A-Za-z_$][\w$]*|any|unknown|never|object)\b/g;
  let match;
  while ((match = asPattern.exec(scrubbed)) !== null) {
    if (match[1] === "const" || isInsideTypeScriptImport(scrubbed, match.index)) continue;
    violations.push(violationFromIndex({ source, filePath, index: match.index, language: "typescript", kind: match[1] === "any" ? "ts_as_any" : "ts_type_assertion", detail: `${reason}; token: ${match[0].trim()}` }));
  }
  const nonNullPattern = /(?:[A-Za-z_$\]\)])\s*!\s*(?=[.\[,);])/g;
  while ((match = nonNullPattern.exec(scrubbed)) !== null) {
    violations.push(violationFromIndex({ source, filePath, index: match.index + match[0].indexOf("!"), language: "typescript", kind: "ts_non_null_assertion", detail: reason }));
  }
  return violations;
}
function isInsideTypeScriptImport(source, index) { const statementStart = Math.max(source.lastIndexOf(";", index), source.lastIndexOf("\n", index)) + 1; return /^\s*import\b/.test(source.slice(statementStart, index)); }

function scanSwift(source, filePath) {
  const scrubbed = stripCommentsAndStrings(source);
  const violations = [];
  scanTokenPattern({ source, scrubbed, filePath, pattern: /\bas\s*!/g, language: "swift", kind: "swift_force_cast", detail: "force cast", violations });
  scanTokenPattern({ source, scrubbed, filePath, pattern: /\btry!/g, language: "swift", kind: "swift_force_try", detail: "force try", violations });
  return violations;
}

function scanKotlin(source, filePath) {
  const scrubbed = stripCommentsAndStrings(source);
  const violations = [];
  const unsafeCastPattern = /\bas\s+(?!\?)([A-Za-z_][\w.]*)/g;
  let match;
  while ((match = unsafeCastPattern.exec(scrubbed)) !== null) {
    if (isKotlinImportAlias(scrubbed, match.index)) continue;
    violations.push(violationFromIndex({ source, filePath, index: match.index, language: "kotlin", kind: "kotlin_unsafe_cast", detail: `unsafe cast to ${match[1]}` }));
  }
  scanTokenPattern({ source, scrubbed, filePath, pattern: /!!(?!=)/g, language: "kotlin", kind: "kotlin_force_unwrap", detail: "force unwrap", violations });
  return violations;
}
function isKotlinImportAlias(source, index) { const lineStart = source.lastIndexOf("\n", index) + 1; return /^\s*import\b/.test(source.slice(lineStart, index)); }
function scanTokenPattern({ source, scrubbed, filePath, pattern, language, kind, detail, violations }) { let match; while ((match = pattern.exec(scrubbed)) !== null) violations.push(violationFromIndex({ source, filePath, index: match.index, language, kind, detail })); }

export function stripCommentsAndStrings(source) {
  let output = "";
  let i = 0;
  while (i < source.length) {
    const char = source[i], next = source[i + 1];
    if (char === "/" && next === "/") { output += "  "; i += 2; while (i < source.length && source[i] !== "\n") { output += " "; i += 1; } continue; }
    if (char === "/" && next === "*") { output += "  "; i += 2; while (i < source.length) { if (source[i] === "*" && source[i + 1] === "/") { output += "  "; i += 2; break; } output += source[i] === "\n" ? "\n" : " "; i += 1; } continue; }
    if (source.startsWith('"""', i)) { output += "   "; i += 3; while (i < source.length) { if (source.startsWith('"""', i)) { output += "   "; i += 3; break; } output += source[i] === "\n" ? "\n" : " "; i += 1; } continue; }
    if (char === "'" || char === '"' || char === "`") { const quote = char; output += " "; i += 1; while (i < source.length) { if (source[i] === "\\") { output += " "; if (i + 1 < source.length) output += source[i + 1] === "\n" ? "\n" : " "; i += 2; continue; } if (source[i] === quote) { output += " "; i += 1; break; } output += source[i] === "\n" ? "\n" : " "; i += 1; } continue; }
    output += char; i += 1;
  }
  return output;
}

function violationFromRange({ source, filePath, node, language, kind, detail }) { const loc = node.loc?.start ?? offsetToLineColumn(source, node.range?.[0] ?? 0); return { path: filePath, line: loc.line, column: loc.column + 1, language, kind, snippet: lineSnippet(source, loc.line), detail }; }
function violationFromIndex({ source, filePath, index, language, kind, detail }) { const loc = offsetToLineColumn(source, index); return { path: filePath, line: loc.line, column: loc.column + 1, language, kind, snippet: lineSnippet(source, loc.line), detail }; }
function offsetToLineColumn(source, offset) { let line = 1, column = 0; for (let i = 0; i < offset; i += 1) { if (source[i] === "\n") { line += 1; column = 0; } else column += 1; } return { line, column }; }
function lineSnippet(source, line) { return source.split(/\r?\n/)[line - 1]?.trim() ?? ""; }
function buildReport(violations, metadata) { const byLanguage = {}, byKind = {}; for (const violation of violations) { byLanguage[violation.language] = (byLanguage[violation.language] ?? 0) + 1; byKind[violation.kind] = (byKind[violation.kind] ?? 0) + 1; } return { version: SCANNER_VERSION, generatedAt: new Date().toISOString(), scanner: { tsMode: metadata.tsMode, excluded: { prefixes: EXCLUDED_PREFIXES, segments: Array.from(EXCLUDED_SEGMENTS).sort(), generatedFilePatterns: GENERATED_FILE_PATTERNS.map((pattern) => pattern.source) } }, total: violations.length, byLanguage: sortObject(byLanguage), byKind: sortObject(byKind), violations }; }
function sortObject(value) { return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b))); }
function compareViolations(a, b) { return a.path.localeCompare(b.path) || a.line - b.line || a.column - b.column || a.kind.localeCompare(b.kind); }
function normalizePath(value) { return value.split(path.sep).join("/"); }
function printTextReport(report) { console.log(`Unsafe cast debt: ${report.total}`); console.log(`TypeScript scanner: ${report.scanner.tsMode}`); console.log(""); console.log("By language:"); for (const [language, count] of Object.entries(report.byLanguage)) console.log(`  ${language}: ${count}`); console.log(""); console.log("By kind:"); for (const [kind, count] of Object.entries(report.byKind)) console.log(`  ${kind}: ${count}`); }
function parseArgs(argv) { const options = { format: "text", check: false, repoRoot: process.cwd() }; for (let i = 0; i < argv.length; i += 1) { const arg = argv[i]; if (arg === "--format") options.format = argv[++i]; else if (arg === "--repo-root") options.repoRoot = argv[++i]; else if (arg === "--check") options.check = true; else if (arg === "--out") options.out = argv[++i]; else if (arg === "--help" || arg === "-h") options.help = true; else throw new Error(`Unknown argument: ${arg}`); } if (!["json", "text"].includes(options.format)) throw new Error(`Unsupported format: ${options.format}`); return options; }
function printHelp() { console.log(`Usage: node tools/type-debt/audit-unsafe-casts.mjs [options]\n\nOptions:\n  --repo-root <path>  Repository root to scan (default: current directory)\n  --format <json|text>\n  --check            Exit non-zero when any violation exists\n  --out <path>       Write the JSON report to a file (atomic, no stdout buffering)\n  --help             Show this help\n`); }
async function main() { const options = parseArgs(process.argv.slice(2)); if (options.help) { printHelp(); return; } const report = await auditUnsafeCasts({ repoRoot: options.repoRoot }); const json = JSON.stringify(report, null, 2); if (options.out) { const { writeFileSync } = await import("node:fs"); writeFileSync(options.out, json); } else if (options.format === "json") console.log(json); else printTextReport(report); if (options.check && report.total > 0) process.exitCode = 1; }
// realpath both sides: on macOS /tmp is a symlink to /private/tmp, so the
// logical argv[1] and the canonical import.meta.url diverge and the old
// equality check silently skipped main() (empty report, exit 0).
const __invoked = process.argv[1] && (() => { try { return realpathSync(path.resolve(process.argv[1])) === realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (__invoked) { main().catch((error) => { console.error(error.message); process.exit(1); }); }
