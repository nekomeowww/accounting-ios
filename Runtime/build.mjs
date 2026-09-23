import { build } from 'esbuild';

await build({
  entryPoints: ['src/jsc.ts'],
  bundle: true,
  platform: 'browser',
  format: 'iife',
  globalName: 'AccountingAgent',
  target: 'es2022',
  outfile: 'dist/agent.js',
  minify: true,
  define: { 'process.env.NODE_ENV': '"production"' },
});
