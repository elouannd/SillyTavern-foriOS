/**
 * iOS entry point for SillyTavern running inside nodejs-mobile.
 */

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ── Derive app container paths from DATADIR ──────────────────────────────────
// nodejs-mobile sets DATADIR = Library/nodejs/data/ inside the app sandbox.
// We derive the container root from there (go up 3 levels: data → nodejs → Library → container)
const dataDir = process.env.DATADIR ?? '/tmp';
const containerRoot = path.resolve(dataDir, '..', '..', '..');  // /var/.../Application/{UUID}/
const documentsBase = path.join(containerRoot, 'Documents');
const appSupportDir = path.join(containerRoot, 'Library', 'Application Support');

// ── Read st_config.json written by AppDelegate ────────────────────────────────
const configPath = path.join(appSupportDir, 'st_config.json');
let _cfg = {};
try { _cfg = JSON.parse(fs.readFileSync(configPath, 'utf8')); } catch (_) {}

const bundlePublicPath = _cfg.bundlePublicPath ?? null;
const bundleServerRoot = _cfg.bundleServerRoot ?? null;

// ── File logging ──────────────────────────────────────────────────────────────
// Write directly to Documents root so it shows in Files app.
const logPath = path.join(documentsBase, 'st-startup.log');
const t0 = Date.now();
const elapsed = () => `+${((Date.now() - t0) / 1000).toFixed(1)}s`;
function log(msg) {
    const line = `[iOS ${elapsed()}] ${msg}\n`;
    try { fs.appendFileSync(logPath, line); } catch (_) {}
}
try { fs.writeFileSync(logPath, `--- st-startup.log @ ${new Date().toISOString()} ---\n`); } catch (_) {}

// ── Neutralize stdout/stderr to prevent SIGPIPE ──────────────────────────────
// On iOS/nodejs-mobile, stdout and stderr are pipes with no reader. Any write
// to them delivers SIGPIPE which kills the process instantly (OS signal, not
// catchable by try/catch or uncaughtException). Replace them with no-ops.
try { process.stdout.write = () => true; } catch (_) {}
try { process.stderr.write = () => true; } catch (_) {}
// Ignore SIGPIPE in case native addons or Node internals write directly
try { process.on('SIGPIPE', () => {}); } catch (_) {}

// ── Register crash handlers early so nothing is swallowed ────────────────────
process.on('uncaughtException', (err) => {
    log(`[FATAL] Uncaught exception: ${err.message}`);
    log(`[FATAL] Stack: ${err.stack ?? '(no stack)'}`);
});
process.on('unhandledRejection', (reason) => {
    if (reason instanceof Error) {
        log(`[FATAL] Unhandled rejection: ${reason.message}`);
        log(`[FATAL] Stack: ${reason.stack ?? '(no stack)'}`);
    } else {
        log(`[FATAL] Unhandled rejection: ${String(reason)}`);
    }
});

log(`Node ${process.version} — server-ios.js loaded`);
log(`__dirname: ${__dirname}`);
log(`DATADIR: ${dataDir}`);
log(`Container root: ${containerRoot}`);
log(`Bundle public: ${bundlePublicPath ?? '(not set)'}`);
log(`Bundle server root: ${bundleServerRoot ?? '(not set)'}`);
log(`Documents base: ${documentsBase}`);

// ── Redirect console to log file ──────────────────────────────────────────────
// On iOS, stdout/stderr are broken pipes — any write triggers SIGPIPE (instant
// process kill, uncatchable by JS). We replace all console methods to write
// ONLY to the log file and never touch stdout/stderr.

/**
 * Serialize a single console argument to a string suitable for the log file.
 * Handles Error objects (preserving message + stack), circular-reference-safe
 * JSON for plain objects, and String() fallback for everything else.
 * @param {unknown} a
 * @returns {string}
 */
function serializeArg(a) {
    if (a instanceof Error) {
        return a.stack ? `${a.stack}` : `${a.name}: ${a.message}`;
    }
    if (typeof a === 'object' && a !== null) {
        try { return JSON.stringify(a); } catch (_) { return String(a); }
    }
    return String(a);
}

// On iOS, stdout/stderr are pipes with no reader — writing to them triggers
// SIGPIPE which kills the process instantly (not catchable by JS).
// So we redirect ALL console output exclusively to the log file.
console.log = (...args) => {
    log(`[LOG] ${args.map(serializeArg).join(' ')}`);
};
console.error = (...args) => {
    log(`[ERR] ${args.map(serializeArg).join(' ')}`);
};
console.warn = (...args) => {
    log(`[WARN] ${args.map(serializeArg).join(' ')}`);
};
console.debug = (...args) => {
    log(`[DBG] ${args.map(serializeArg).join(' ')}`);
};
console.info = (...args) => {
    log(`[INFO] ${args.map(serializeArg).join(' ')}`);
};

// ── Paths ─────────────────────────────────────────────────────────────────────
const documentsDir = path.join(documentsBase, 'SillyTavern');
const iosConfigPath = path.join(__dirname, 'config.yaml');

// ST_PUBLIC_DIR: serve SillyTavern frontend from bundle (read-only).
const iosFrontendDir = bundlePublicPath ?? path.join(__dirname, 'public');

// ST_SERVER_DIR: the actual server directory (on-device, has plugins/).
// This is where nodejs-mobile copies nodejs-project to: Library/nodejs/public/
const iosServerDir = __dirname;

// ST_DEFAULTS_DIR: where default/ templates live (in bundle, read-only).
// Content manager looks for ST_DEFAULTS_DIR/default/ = App.app/public/st-defaults/default/
const iosDefaultsDir = bundleServerRoot ?? __dirname;

log(`Frontend dir:  ${iosFrontendDir}`);
log(`Server dir:    ${iosServerDir}`);
log(`Defaults dir:  ${iosDefaultsDir}`);
log(`Documents dir: ${documentsDir}`);

// ── Ensure data dir exists ────────────────────────────────────────────────────
try {
    if (!fs.existsSync(documentsDir)) {
        fs.mkdirSync(documentsDir, { recursive: true });
        log('Created documents dir');
    }
} catch (e) {
    log(`Warning: could not create documents dir: ${e.message}`);
}

// ── Env vars for bundle ───────────────────────────────────────────────────────
process.env.ST_PUBLIC_DIR = iosFrontendDir;
process.env.ST_SERVER_DIR = iosServerDir;
process.env.ST_DEFAULTS_DIR = iosDefaultsDir;

// ── CLI args ──────────────────────────────────────────────────────────────────
process.argv = [
    process.argv[0],
    __filename,
    '--dataRoot', documentsDir,
    '--configPath', iosConfigPath,
];
log(`argv: ${process.argv.slice(2).join(' ')}`);

// ── Bridge ────────────────────────────────────────────────────────────────────
let bridgeChannel = null;
try {
    const bridge = await import('bridge');
    bridgeChannel = bridge.channel;
    log('Bridge loaded');
} catch {
    log('Bridge not available (dev mode)');
}

async function waitForPort(port, maxWaitMs = 60000) {
    const { createConnection } = await import('node:net');
    const start = Date.now();
    return new Promise((resolve) => {
        const attempt = () => {
            const sock = createConnection(port, '127.0.0.1');
            sock.once('connect', () => { sock.destroy(); resolve(true); });
            sock.once('error', () => {
                sock.destroy();
                if (Date.now() - start < maxWaitMs) setTimeout(attempt, 500);
                else resolve(false);
            });
        };
        attempt();
    });
}

// ── Start server ──────────────────────────────────────────────────────────────
try {
    log('Importing server-bundle.mjs...');
    await import('./server-bundle.mjs');
    log('Bundle imported — waiting for port 8000...');

    const up = await waitForPort(8000);
    if (up) {
        log('Port 8000 is up!');
        if (bridgeChannel) {
            bridgeChannel.send('serverReady', { port: 8000 });
            log('Sent serverReady to bridge');
        }
    } else {
        log('WARNING: port 8000 never opened after 60s');
    }
} catch (error) {
    log(`FATAL: ${error}`);
    log(`Stack: ${error.stack}`);
    if (bridgeChannel) bridgeChannel.send('serverError', { message: String(error) });
}
