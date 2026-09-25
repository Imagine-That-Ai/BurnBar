import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";
import prettier from "eslint-config-prettier";

export default [
  {
    ignores: [
      "lib/**",
      "node_modules/**",
      "src/**/*.generated.ts",
    ],
  },
  {
    files: ["src/**/*.ts"],
    languageOptions: {
      ecmaVersion: 2022,
      parser: tsParser,
      sourceType: "module",
    },
    plugins: {
      "@typescript-eslint": tsPlugin,
    },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      "no-console": "error",

      // Wave 4: raw fetch() bypasses the resilience helpers (retry, timeout,
      // circuit breaking). All production HTTP MUST go through providerFetch,
      // resilientFetch, or the *WithResilience wrappers.
      // no-restricted-globals catches bare fetch(); no-restricted-properties
      // catches the globalThis.fetch spelling the old regex missed. Tests and
      // the canonical owner (resilienceHelpers.ts) are carved out below.
      "no-restricted-globals": [
        "error",
        {
          name: "fetch",
          message:
            "Use providerFetch/resilientFetch from resilienceHelpers.js — raw fetch() bypasses retry/timeout/circuit breaking.",
        },
      ],
      "no-restricted-properties": [
        "error",
        {
          object: "globalThis",
          property: "fetch",
          message:
            "Use providerFetch/resilientFetch from resilienceHelpers.js — raw globalThis.fetch() bypasses retry/timeout/circuit breaking.",
        },
      ],

      // F-RR09-002: the raw firebase-functions logger bypasses the PII/secret
      // scrubber in logging.ts. All production logging MUST go through
      // logInfo/logWarn/logError so UIDs, tokens, and path-embedded identifiers
      // are redacted. (Tests may still `vi.mock("firebase-functions/logger")`
      // — that is a string arg, not an import, so this rule does not flag it.)
      "no-restricted-imports": [
        "error",
        {
          paths: [
            {
              name: "firebase-functions/logger",
              message:
                "Use logInfo/logWarn/logError from ./logging.js — the raw firebase-functions logger bypasses the PII/secret scrubber (F-RR09-002).",
            },
          ],
        },
      ],

      // Enforce cyclomatic complexity threshold — warn on existing violations
      "complexity": ["warn", { max: 25 }],

      // Enforce naming conventions — warn to allow existing patterns to be
      // incrementally fixed; new code should follow these conventions
      "@typescript-eslint/naming-convention": [
        "warn",
        // camelCase for variables and functions
        {
          selector: "variable",
          format: ["camelCase", "UPPER_CASE", "PascalCase"],
          leadingUnderscore: "allowSingleOrDouble",
          trailingUnderscore: "allowSingleOrDouble",
        },
        {
          selector: "function",
          format: ["camelCase", "PascalCase"],
        },
        // PascalCase for types, interfaces, classes, enums
        {
          selector: "typeLike",
          format: ["PascalCase"],
        },
        {
          selector: "interface",
          format: ["PascalCase"],
          custom: { regex: "^I[A-Z]", match: false },
        },
        // PascalCase or UPPER_CASE for enum members
        {
          selector: "enumMember",
          format: ["PascalCase", "UPPER_CASE"],
        },
        // camelCase for class methods and properties
        {
          selector: "classMethod",
          format: ["camelCase"],
          leadingUnderscore: "allow",
        },
        {
          selector: "classProperty",
          format: ["camelCase", "UPPER_CASE"],
          leadingUnderscore: "allow",
        },
      ],

      // Disallow unused vars (use @typescript-eslint version)
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],

      // Warn on very large files — split these incrementally
      "max-lines": ["warn", { max: 600, skipComments: true, skipBlankLines: true }],
    },
  },
  {
    files: ["src/logging.ts"],
    rules: {
      "no-console": "off",
    },
  },
  {
    // Canonical fetch owner: resilienceHelpers.ts holds the one sanctioned
    // raw fetch() all wrappers build on (asserted by
    // scripts/ci/verify-resilience-wiring.sh).
    files: ["src/resilienceHelpers.ts"],
    rules: {
      "no-restricted-globals": "off",
      "no-restricted-properties": "off",
    },
  },
  {
    // Integration tests drive real endpoints; unit-test fetch stubs pass a
    // string ('fetch'), which these rules do not flag.
    files: ["src/__tests__/**/*.ts", "src/**/*.test.ts"],
    rules: {
      "no-restricted-globals": "off",
      "no-restricted-properties": "off",
    },
  },
  // Must be last: turns off all ESLint rules that conflict with Prettier formatting
  prettier,
];
