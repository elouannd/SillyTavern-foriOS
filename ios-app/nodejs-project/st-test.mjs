import path from 'node:path';
const cwd = process.cwd();
process.env.ST_PUBLIC_DIR = path.join(cwd, 'public');
process.argv = [
  process.argv[0],
  path.join(cwd, 'server.js'),
  '--dataRoot', '/tmp/st-ios-test',
  '--configPath', path.join(cwd, 'config.yaml'),
];
await import('./server-bundle.mjs');
