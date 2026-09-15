const esbuild = require('esbuild');

esbuild
  .build({
    entryPoints: ['src/extension.ts'],
    bundle: true,
    platform: 'node',
    format: 'cjs',
    target: 'node20',
    outfile: 'dist/extension.js',
    external: ['vscode'],
    minify: true,
    sourcemap: true,
    logLevel: 'info',
  })
  .catch(() => process.exit(1));
