import js from '@eslint/js';
import tseslint from '@typescript-eslint/eslint-plugin';
import tsparser from '@typescript-eslint/parser';
import globals from 'globals';

export default [
  {
    ignores: [
      'dist/**',
      '.vscode-test/**',
      'node_modules/**',
      '*.vsix',
      '.build/**'
    ]
  },
  js.configs.recommended,
  // Webview JS files - browser environment, no TypeScript
  {
    files: ['src/webview/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'script',
      globals: {
        ...globals.browser,
        acquireVsCodeApi: 'readonly'
      }
    },
    rules: {
      'no-undef': 'error',
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      'default-case': 'warn',
      'no-empty-function': 'warn',
      'eqeqeq': 'error',
      'no-extra-semi': 'error'
    }
  },
  // Daemon TypeScript files - Node.js environment
  {
    files: ['src/daemon/**/*.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module'
      },
      globals: {
        ...globals.node,
        // Node.js types
        NodeJS: 'readonly'
      }
    },
    plugins: {
      '@typescript-eslint': tseslint
    },
    rules: {
      ...tseslint.configs.recommended.rules,
      '@typescript-eslint/no-unused-vars': ['warn', {
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_'
      }],
      '@typescript-eslint/explicit-function-return-type': 'off',
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
      'semi': ['error', 'always'],
      'quotes': ['error', 'single', { avoidEscape: true }],
      'comma-dangle': ['error', 'never'],
      'brace-style': ['error', '1tbs'],
      'indent': ['error', 2],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      'no-debugger': 'warn',
      'prefer-const': 'warn',
      'no-var': 'error',
      'eqeqeq': ['error', 'always'],
      'curly': ['error', 'all'],
      'default-case': 'warn',
      'no-empty-function': 'off',
      'no-eval': 'error',
      'no-floating-decimal': 'error',
      'no-implicit-coercion': ['warn', { boolean: true, number: true, string: true }],
      'no-multi-spaces': 'warn',
      'no-multiple-empty-lines': ['warn', { max: 2, maxEOF: 1 }],
      'no-trailing-spaces': 'warn',
      'no-with': 'error',
      'space-infix-ops': 'error',
      'keyword-spacing': 'warn',
      'space-before-blocks': 'warn'
    }
  },
  // Extension TypeScript files - VS Code + Node.js + browser (for shared code)
  {
    files: ['src/**/*.ts', '!src/daemon/**/*.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module'
      },
      globals: {
        ...globals.browser,
        ...globals.node,
        // VS Code API globals
        Thenable: 'readonly',
        CancellationToken: 'readonly',
        Disposable: 'readonly',
        Event: 'readonly',
        Uri: 'readonly',
        Range: 'readonly',
        Position: 'readonly',
        Location: 'readonly',
        WorkspaceFolder: 'readonly',
        DocumentSelector: 'readonly',
        FormattingOptions: 'readonly',
        TextEdit: 'readonly',
        Hover: 'readonly',
        Definition: 'readonly',
        DefinitionLink: 'readonly',
        ReferenceContext: 'readonly',
        locations: 'readonly',
        CommentRule: 'readonly',
        FoldingContext: 'readonly',
        SignatureHelp: 'readonly',
        CompletionContext: 'readonly',
        CodeLensContext: 'readonly',
        MarkdownString: 'readonly',
        TextDocument: 'readonly',
        Terminal: 'readonly',
        EnvironmentVariableCollection: 'readonly',
        CustomTerminal: 'readonly',
        // Webview globals (VS Code webview panel)
        acquireVsCodeApi: 'readonly'
      }
    },
    plugins: {
      '@typescript-eslint': tseslint
    },
    rules: {
      ...tseslint.configs.recommended.rules,
      '@typescript-eslint/no-unused-vars': ['warn', {
        argsIgnorePattern: '^_',
        varsIgnorePattern: '^_'
      }],
      '@typescript-eslint/explicit-function-return-type': 'off',
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
      'semi': ['error', 'always'],
      'quotes': ['error', 'single', { avoidEscape: true }],
      'comma-dangle': ['error', 'never'],
      'brace-style': ['error', '1tbs'],
      'indent': ['error', 2],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
      'no-debugger': 'warn',
      'prefer-const': 'warn',
      'no-var': 'error',
      'eqeqeq': ['error', 'always'],
      'curly': ['error', 'all'],
      'default-case': 'warn',
      'no-empty-function': 'off',
      'no-eval': 'error',
      'no-floating-decimal': 'error',
      'no-implicit-coercion': ['warn', { boolean: true, number: true, string: true }],
      'no-multi-spaces': 'warn',
      'no-multiple-empty-lines': ['warn', { max: 2, maxEOF: 1 }],
      'no-trailing-spaces': 'warn',
      'no-with': 'error',
      'space-infix-ops': 'error',
      'keyword-spacing': 'warn',
      'space-before-blocks': 'warn'
    }
  }
];
