/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    /* ── Circular dependencies ─────────────────────────────────────────── */
    {
      name: "no-circular",
      severity: "error",
      comment:
        "Circular dependencies make code harder to reason about and test.",
      from: {},
      to: {
        circular: true,
      },
    },

    /* ── Test files must not import production paths ────────────────────── */
    {
      name: "no-test-imports-production-directly",
      severity: "warn",
      comment:
        "Test files should import from the module under test, not from unrelated production modules.",
      from: {
        path: "^src/.*\\.test\\.ts$",
      },
      to: {
        pathNot: [
          "^src/",
          "node_modules",
        ],
      },
    },

    /* ── No relative imports reaching outside own sub-tree ─────────────── */
    {
      name: "no-reach-into-sibling-module",
      severity: "warn",
      comment:
        "Prefer importing from a module's public index rather than reaching into its internals.",
      from: {
        path: "^src/",
      },
      to: {
        path: "\\.\\./\\.\\.",
      },
    },

    /* ── External modules must not come from test files ────────────────── */
    {
      name: "no-external-from-test",
      severity: "warn",
      comment:
        "Test-only external packages should not bleed into production imports.",
      from: {
        path: "^src/.*\\.(spec|test)\\.ts$",
      },
      to: {
        dependencyTypes: ["npm-dev"],
      },
    },

    /* ── Webview files should not import extension host modules ────────── */
    {
      name: "no-webview-imports-extension-host",
      severity: "warn",
      comment:
        "Webview JS/TS must not directly import extension-host-only modules; communicate via VS Code message protocol.",
      from: {
        path: "^src/webview/",
      },
      to: {
        path: "^src/daemon/",
      },
    },

    /* ── Daemon files should not import webview modules ─────────────────── */
    {
      name: "no-daemon-imports-webview",
      severity: "warn",
      comment:
        "Daemon / extension-host code must not depend on webview-only modules.",
      from: {
        path: "^src/daemon/",
      },
      to: {
        path: "^src/webview/",
      },
    },

    /* ── Orphaned modules ───────────────────────────────────────────────── */
    {
      name: "no-orphans",
      severity: "warn",
      comment:
        "Modules that nothing depends on are likely dead code.",
      from: {
        orphan: true,
        pathNot: [
          "\\.d\\.ts$",
          "(^|/)index\\.ts$",
          "^src/extension\\.ts$",
        ],
      },
      to: {},
    },
  ],

  options: {
    doNotFollow: {
      path: "node_modules",
      dependencyTypes: [
        "npm",
        "npm-dev",
        "npm-optional",
        "npm-peer",
        "npm-bundled",
        "npm-no-pkg",
      ],
    },

    exclude: {
      path: [
        "node_modules",
        "dist",
        "\\.vscode-test",
        "\\.build",
        "\\.d\\.ts$",
      ],
    },

    includeOnly: {
      path: "^src/",
    },

    tsConfig: {
      fileName: "tsconfig.json",
    },

    enhancedResolveOptions: {
      exportsFields: ["exports"],
      conditionNames: ["import", "require", "node", "default"],
    },

    reporterOptions: {
      dot: {
        collapsePattern: "node_modules/[^/]+",
      },
      archi: {
        collapsePattern:
          "^(node_modules|src/[^/]+/[^/]+|packages/[^/]+)/",
      },
      text: {
        highlightFocused: true,
      },
    },
  },
};
