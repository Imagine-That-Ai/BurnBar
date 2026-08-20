/** @type {import('dependency-cruiser').IConfiguration} */
module.exports = {
  forbidden: [
    {
      name: 'no-circular',
      severity: 'error',
      from: {},
      to: { circular: true }
    },
    {
      name: 'content-does-not-own-native-bridge',
      severity: 'error',
      from: { path: '^src/content/' },
      to: { path: '^src/background/' }
    },
    {
      name: 'popup-does-not-own-page-automation',
      severity: 'error',
      from: { path: '^src/popup/' },
      to: { path: '^src/content/' }
    },
    {
      name: 'shared-has-no-surface-dependencies',
      severity: 'error',
      from: { path: '^src/shared/' },
      to: { path: '^src/(background|content|popup)/' }
    }
  ],
  options: {
    doNotFollow: { path: 'node_modules' },
    exclude: { path: ['node_modules', 'dist', 'coverage', '\\.d\\.ts$'] },
    includeOnly: { path: '^src/' },
    tsConfig: { fileName: 'tsconfig.json' },
    enhancedResolveOptions: {
      exportsFields: ['exports'],
      conditionNames: ['import', 'browser', 'default']
    }
  }
};
