/**
 * iOS esbuild entry point.
 * Replicates server.js logic but wraps the async import in an IIFE so the
 * bundle has NO top-level await — avoiding the CJS shim + top-level await
 * conflict that crashes Node when yargs (CJS) is bundled with ESM top-level await.
 */
import { CommandLineParser } from './src/command-line.js';
import { serverDirectory } from './src/server-directory.js';

const _t0 = Date.now();
const _el = () => `+${((Date.now() - _t0) / 1000).toFixed(1)}s`;

console.log(`[bundle ${_el()}] server-ios-entry.js — Node ${process.version}`);
console.log(`[bundle ${_el()}] serverDirectory: ${serverDirectory}`);

const cliArgs = new CommandLineParser().parse(process.argv);
globalThis.DATA_ROOT = cliArgs.dataRoot;
globalThis.COMMAND_LINE_ARGS = cliArgs;
process.chdir(serverDirectory);
console.log(`[bundle ${_el()}] CLI parsed — dataRoot: ${cliArgs.dataRoot}`);

// Async IIFE — NOT top-level await, avoids CJS+ESM module format conflict
(async () => {
    try {
        console.log(`[bundle ${_el()}] Starting server-main.js...`);
        await import('./src/server-main.js');
        console.log(`[bundle ${_el()}] server-main.js returned`);
    } catch (error) {
        console.error(`[bundle ${_el()}] FATAL in server-main.js:`, error);
    }
})();
