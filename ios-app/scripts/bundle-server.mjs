#!/usr/bin/env node
/**
 * bundle-server.mjs
 *
 * Uses esbuild to bundle SillyTavern's Express backend into a single ESM file.
 * This is required for nodejs-mobile on iOS because:
 *  - The plugin copies the nodejs-project directory on every app update
 *  - node_modules alone is 151MB / 11,902 files → multi-minute hang on launch
 *  - One bundled file copies in milliseconds
 *
 * Output: nodejs-project/server-bundle.mjs
 * Entry:  nodejs-project/src/server-main.js
 */

import { build } from 'esbuild';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const iosAppDir = dirname(__dirname);
const nodejsProject = join(iosAppDir, 'nodejs-project');
const entryPoint = join(nodejsProject, 'server-ios-entry.js');
const outFile = join(nodejsProject, 'server-bundle.mjs');

if (!existsSync(entryPoint)) {
    console.error(`❌ Entry point not found: ${entryPoint}`);
    console.error('   Run prepare-ios.sh Step 1 first to sync src/');
    process.exit(1);
}

// ── Stub plugin ───────────────────────────────────────────────────────────────
// Modules that cannot run on iOS (no native binaries, no child_process, etc.)
// are replaced with minimal no-op stubs so the bundle doesn't crash on import.
// All real functionality for these is either absent on iOS or gracefully skipped
// by the calling code (which already checks for null/undefined return values).

const STUBS = {
    // simple-git: used for plugin git updates and server version info
    // On iOS: git is not available; these features are silently skipped
    'simple-git': `
        export const CheckRepoActions = { IS_REPO_ROOT: 'IS_REPO_ROOT', IS_REPO_ROOT_OR_BARE: 'IS_REPO_ROOT_OR_BARE' };
        const noop = () => Promise.resolve(null);
        const fakeGit = () => new Proxy({}, { get: () => noop });
        export default fakeGit;
    `,

    // webpack + config: used for hot-reload dev server middleware.
    // On iOS: frontend is pre-built; webpack compilation never runs.
    // Stub the entire middleware module so runWebpackCompiler resolves instantly.
    'webpack': `export default function webpack() { return { run: (cb) => cb(null, { toString: () => '' }), close: (cb) => cb() }; }`,
    '../../webpack.config.js': `export default function getPublicLibConfig() { return { output: { path: '', filename: '' }, stats: {} }; }`,
    './middleware/webpack-serve.js': `
        export default function getWebpackServeMiddleware() {
            function devMiddleware(req, res, next) { next(); }
            devMiddleware.runWebpackCompiler = () => Promise.resolve();
            return devMiddleware;
        }
    `,

    // open: opens system browser — not applicable on iOS
    'open': `export default async function open() {}`,

    // vectra + gpt-3-encoder: local vector store used for long-term memory.
    // gpt-3-encoder tries to readFileSync('encoder.json') at CJS init time —
    // the JSON data file is not bundled by esbuild → crashes immediately.
    // Vector memory requires persistent storage setup anyway; stub both out.
    'vectra': `
        export class LocalIndex {
            constructor() {}
            async isIndexCreated() { return false; }
            async createIndex() {}
            async insertItem() {}
            async queryItems() { return []; }
            async deleteItem() {}
            async listItems() { return []; }
            async beginUpdate() {}
            async endUpdate() {}
            async cancelUpdate() {}
        }
        export default { LocalIndex };
    `,
    'gpt-3-encoder': `
        module.exports = {
            encode: (text) => [],
            decode: (tokens) => '',
            bpe: (token) => [],
        };
    `,
    // plugins, but esbuild picks it up. The actual Jimp instance comes from
    // src/jimp.js via @jimp/core directly — this stub is never called.
    'jimp': `
        export class Jimp {}
        export const JimpMime = {};
        export default Jimp;
    `,
};

const stubPlugin = {
    name: 'ios-stubs',
    setup(build) {
        for (const [moduleName, stubCode] of Object.entries(STUBS)) {
            const filter = new RegExp(`^${moduleName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`);
            build.onResolve({ filter }, args => ({
                path: args.path,
                namespace: `ios-stub:${moduleName}`,
            }));
            const ns = `ios-stub:${moduleName}`;
            build.onLoad({ filter: /.*/, namespace: ns }, () => ({
                contents: stubCode,
                loader: 'js',
            }));
        }
    },
};

// ─────────────────────────────────────────────────────────────────────────────

console.log('📦 Bundling SillyTavern server with esbuild...');
console.log(`   Entry: ${entryPoint}`);
console.log(`   Output: ${outFile}`);
console.log('');

const result = await build({
    entryPoints: [entryPoint],
    bundle: true,
    platform: 'node',
    target: 'node18',
    format: 'esm',
    outfile: outFile,
    logLevel: 'warning',
    allowOverwrite: true,
    mainFields: ['main', 'module'],
    conditions: ['node', 'require', 'default'],
    sourcemap: false,

    // CJS modules bundled into ESM output call require() for Node builtins.
    // Use a unique alias to avoid colliding with esbuild's own createRequire shim.
    // CJS modules need require(), __dirname, __filename in the ESM bundle.
    banner: {
        js: [
            `import { createRequire as __iosCreateRequire } from 'node:module';`,
            `import { fileURLToPath as __iosFileURLToPath } from 'node:url';`,
            `import { dirname as __iosDirname } from 'node:path';`,
            `const require = __iosCreateRequire(import.meta.url);`,
            `const __filename = __iosFileURLToPath(import.meta.url);`,
            `const __dirname = __iosDirname(__filename);`,
        ].join(' '),
    },

    plugins: [stubPlugin],

    // True externals: binary .node addons and WASM blobs that must stay
    // as dynamic imports (already wrapped in try/catch in source)
    external: [
        '*.node',
        '@jimp/wasm-avif', '@jimp/wasm-jpeg', '@jimp/wasm-png',
        '@jimp/wasm-webp', '@jimp/wasm-bmp', '@jimp/wasm-gif', '@jimp/wasm-tiff',
        'sillytavern-transformers', 'onnxruntime-node',
        'tiktoken',
        '@jsquash/avif', '@jsquash/jpeg', '@jsquash/jxl',
        '@jsquash/oxipng', '@jsquash/png', '@jsquash/webp',
    ],
});

if (result.errors.length > 0) {
    console.error('❌ esbuild errors:');
    result.errors.forEach(e => console.error(' ', e.text));
    process.exit(1);
}

if (result.warnings.length > 0) {
    console.log(`⚠️  ${result.warnings.length} warnings`);
}

console.log('✅ Bundle complete!');
console.log('');
