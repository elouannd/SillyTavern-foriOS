# SillyTavern iOS Port — Technical Documentation

> Architecture, build pipeline, runtime flow, and bug fixes for the iOS port of SillyTavern.

---

## Table of Contents

1. [High-Level Architecture](#1-high-level-architecture)
2. [Build Pipeline (`prepare-ios.sh`)](#2-build-pipeline)
3. [esbuild Server Bundle](#3-esbuild-server-bundle)
4. [Webpack Frontend Bundle (`lib.js`)](#4-webpack-frontend-bundle)
5. [On-Device Startup Flow](#5-on-device-startup-flow)
6. [Path Architecture](#6-path-architecture)
7. [Skip-Copy Optimisation](#7-skip-copy-optimisation)
8. [Xcode Build Phases](#8-xcode-build-phases)
9. [File Reference](#9-file-reference)
10. [Bugs Found & Fixed](#10-bugs-found--fixed)
11. [Known Limitations](#11-known-limitations)

---

## 1. High-Level Architecture

The iOS port wraps the full SillyTavern Node.js backend inside a native iOS app:

```
┌──────────────────────────────────────────────────────────────┐
│  iOS App (Capacitor Shell)                                   │
│                                                              │
│  ┌────────────────────┐    ┌─────────────────────────────┐  │
│  │  WKWebView          │◄──│  Express Server (Node.js)   │  │
│  │  (SillyTavern UI)   │   │  localhost:8000             │  │
│  │                      │   │                             │  │
│  │  Loads from          │   │  Runs via nodejs-mobile     │  │
│  │  http://localhost    │   │  in a background thread     │  │
│  │  :8000               │   │                             │  │
│  └────────────────────┘    └─────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  Native Layer (Swift)                                  │  │
│  │  • AppDelegate — config, skip-copy optimisation        │  │
│  │  • SillyTavernViewController — loading overlay, polls  │  │
│  │  • @choreruiz/capacitor-node-js — nodejs-mobile plugin │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

**Key technologies:**
- **Capacitor 8.2** — Native iOS shell with WKWebView
- **@choreruiz/capacitor-node-js** — nodejs-mobile plugin (runs Node 18 on-device)
- **esbuild** — Bundles the entire SillyTavern backend into one ~16MB `.mjs` file
- **Webpack** — Pre-compiles frontend npm libraries (`lib.js`) for the browser

**Why esbuild?** The nodejs-mobile plugin copies `nodejs-project/` to the device sandbox on every app update. Bundling 11,900+ `node_modules` files into one `server-bundle.mjs` makes this copy fast (~1s vs 30–60s).

**Why webpack pre-build?** On desktop, SillyTavern compiles `public/lib.js` on-the-fly via the webpack-serve middleware. On iOS, webpack is stubbed out (no JIT compiler in nodejs-mobile), so `lib.js` must be pre-compiled at build time. Without this, the browser gets the raw source with bare npm imports (`import lodash from 'lodash'`) which browsers cannot resolve — resulting in a blank page.

---

## 2. Build Pipeline

All iOS preparation is done by `ios-app/scripts/prepare-ios.sh`. Run it from the `ios-app/` directory before building in Xcode.

### Steps

| Step | What it does | Why |
|------|-------------|-----|
| **1** | Copy `src/`, `default/`, `plugins/`, `post-install.js`, `server.js` → `nodejs-project/` | Sync latest backend code from repo root |
| **2** | `npm install --omit=dev` in `nodejs-project/` | Install production dependencies for Node 18 |
| **2.5** | `node scripts/bundle-server.mjs` | Bundle server into `server-bundle.mjs` (~16MB) |
| **3** | Patch `@choreruiz/capacitor-node-js/Package.swift` | Fix capacitor-swift-pm version pin (8.1.0 → 8.2.0) |
| **4** | Build `nodejs-project-deploy/` | Slim deploy dir: only `server-ios.js`, `server-bundle.mjs`, `config.yaml`, `package.json`, `plugins/` |
| **4.5** | `npx cap sync ios` | Copy frontend assets to Xcode project |
| **4.6** | Pre-build `lib.js` with webpack (`forceDist=true`) | Compile npm libraries for browser (replaces raw source) |
| **5** | Copy `nodejs-project-deploy/` → `ios/App/App/public/nodejs-project/` | Inject backend into Xcode bundle |
| **5.5** | Copy `default/` → `ios/App/App/public/st-defaults/default/` | Default content templates (read from bundle, not copied to device) |
| **6** | Copy plugin `builtin_modules/` → `ios/App/App/public/builtin_modules/` | nodejs-mobile bridge module (`bridge` channel for IPC) |

### File size budget

| File | Size | Contents |
|------|------|----------|
| `server-bundle.mjs` | ~14 MB | Entire SillyTavern backend (Express + all routes + all dependencies) |
| `server-ios.js` | ~8 KB | iOS entry point (logging, path derivation, env setup) |
| `lib.js` (compiled) | ~1.9 MB | Frontend npm libraries (lodash, fuse.js, DOMPurify, etc.) |
| `st-defaults/default/` | ~2 MB | Default character cards, chat templates, config |

---

## 3. esbuild Server Bundle

**Config:** `ios-app/scripts/bundle-server.mjs`
**Entry:** `ios-app/nodejs-project/server-ios-entry.js`
**Output:** `ios-app/nodejs-project/server-bundle.mjs`

### Why server-ios-entry.js exists

SillyTavern's `server.js` uses top-level `await`. When esbuild bundles this with CJS modules (like `yargs`), it emits a CJS compatibility shim that conflicts with top-level `await`. The `server-ios-entry.js` wrapper avoids this by wrapping the async import in an IIFE:

```javascript
// No top-level await — avoids CJS+ESM conflict
(async () => {
    await import('./src/server-main.js');
})();
```

### CJS compatibility banner

esbuild's ESM output doesn't provide `require()`, `__filename`, or `__dirname`. The bundle injects a banner that recreates these:

```javascript
import { createRequire as __iosCreateRequire } from 'node:module';
const require = __iosCreateRequire(import.meta.url);
const __filename = __iosFileURLToPath(import.meta.url);
const __dirname = __iosDirname(__filename);
```

### Stubbed modules

These modules are replaced with no-op implementations since they're unavailable or unnecessary on iOS:

| Module | Reason for stub |
|--------|----------------|
| `simple-git` | Uses `child_process` (not in nodejs-mobile sandbox) |
| `webpack` | Build-time only; not needed at runtime |
| `../../webpack.config.js` | Webpack config (references webpack) |
| `./middleware/webpack-serve.js` | Webpack dev middleware → replaced with `next()` passthrough |
| `open` | Opens system browser (not applicable) |
| `vectra` | Local vector store; requires persistent storage setup |
| `gpt-3-encoder` | Tries `readFileSync('encoder.json')` at CJS init (file not bundled) |
| `jimp` | Replaced with direct `@jimp/core` import |

### External modules (not bundled)

- All `.node` native addons
- `@jimp/wasm-*` codecs (AVIF, JPEG, PNG, WebP) — dynamic imports, fail gracefully
- `sillytavern-transformers` / `onnxruntime-node` — ONNX runtime (C++ native, not on iOS)
- `tiktoken` — native token counter (optional, falls back to approximate counting)

---

## 4. Webpack Frontend Bundle

### The problem

`public/lib.js` bundles 21 npm packages for the browser:

```javascript
import lodash from 'lodash';
import Fuse from 'fuse.js';
import DOMPurify from 'dompurify';
import hljs from 'highlight.js';
import localforage from 'localforage';
import Handlebars from 'handlebars';
import css from '@adobe/css-tools';
// ... 14 more packages
```

On desktop, the webpack-serve middleware (`src/middleware/webpack-serve.js`) compiles this on-the-fly and intercepts `GET /lib.js` requests to serve the compiled bundle.

On iOS, webpack is stubbed. If the raw `lib.js` is served, the browser gets bare specifiers like `import lodash from 'lodash'` which it cannot resolve. **All frontend JavaScript fails silently and the page is blank.**

### The fix

`prepare-ios.sh` Step 4.6 runs webpack with `forceDist=true`:

```bash
node --input-type=module -e "
import getPublicLibConfig from './webpack.config.js';
import webpack from 'webpack';
const config = getPublicLibConfig(true);
const compiler = webpack(config);
compiler.run((err, stats) => { ... });
"
```

This compiles `lib.js` to `dist/_webpack/{version}/output/lib.js` (~1.9MB), which is then copied over the raw version in `ios/App/App/public/lib.js`.

### Webpack config details

```javascript
{
  mode: 'production',
  entry: 'public/lib.js',
  output: {
    path: 'dist/_webpack/{version}/output/',
    filename: 'lib.js',
    libraryTarget: 'module'   // ESM output
  },
  experiments: { outputModule: true },
  cache: {
    type: 'filesystem',
    cacheDirectory: 'dist/_webpack/{version}/cache/',
    compression: 'gzip'
  }
}
```

---

## 5. On-Device Startup Flow

### Phase 1: Native (Swift)

```
App Launch
    │
    ▼
AppDelegate.didFinishLaunchingWithOptions
    │
    ├── writeBundlePathConfig()
    │   └── Write st_config.json to Application Support/
    │       { bundlePublicPath, bundleServerRoot, documentsPath }
    │
    ├── skipNodeJSCopyIfFilesExist()
    │   └── Compare server-bundle.mjs + server-ios.js byte sizes
    │       ├── Match → set UserDefaults, skip copy ⚡️
    │       └── Mismatch → delete on-disk copy, force recopy 🔄
    │
    ▼
CAPBridgeViewController.viewDidLoad (super)
    │
    ├── Capacitor initialises plugins
    │   └── NodeJSPlugin.load()
    │       └── startEngine(projectDir: "nodejs-project", startMode: "auto")
    │           └── New thread (2MB stack, "NodeJS-Engine")
    │               ├── copyNodeProjectFromBundle()
    │               │   ├── Copy nodejs-project → Library/nodejs/public/
    │               │   └── Copy builtin_modules → Library/nodejs/builtin_modules/
    │               ├── Create Library/nodejs/data/ (persistent storage)
    │               ├── Set env: DATADIR, NODE_PATH, TMPDIR
    │               ├── Build argv: ["node", ".../server-ios.js"]
    │               └── nodeProcess.start() ← BLOCKS until Node exits
    │
    ▼
SillyTavernViewController.viewDidLoad
    ├── Show loading overlay ("Starting local server…")
    ├── Start polling http://localhost:8000 (every 0.5s, max 180s)
    └── Start elapsed timer (updates status label)
```

### Phase 2: Node.js

```
server-ios.js
    │
    ├── Derive paths from DATADIR env var
    │   containerRoot = DATADIR/../../..
    │   documentsBase = containerRoot/Documents
    │   appSupportDir = containerRoot/Library/Application Support
    │
    ├── Read st_config.json → bundlePublicPath, bundleServerRoot
    │
    ├── Set up file logging → Documents/st-startup.log
    │
    ├── Register crash handlers (uncaughtException, unhandledRejection)
    │
    ├── Redirect console.log/error/warn/debug → log file
    │
    ├── Set env vars:
    │   ST_PUBLIC_DIR  = bundlePublicPath (App.app/public/)
    │   ST_SERVER_DIR  = __dirname (Library/nodejs/public/)
    │   ST_DEFAULTS_DIR = bundleServerRoot (App.app/public/st-defaults/)
    │
    ├── Set process.argv:
    │   --dataRoot Documents/SillyTavern
    │   --configPath Library/nodejs/public/config.yaml
    │
    ├── import('bridge') → bridge.channel (IPC to Swift)
    │
    ├── await import('./server-bundle.mjs')
    │   └── server-ios-entry.js (inside bundle)
    │       ├── Parse CLI args → DATA_ROOT, COMMAND_LINE_ARGS
    │       ├── process.chdir(serverDirectory)
    │       └── (async () => import('./src/server-main.js'))()
    │           └── Express app: middleware, routes, listen(:8000)
    │
    ├── waitForPort(8000) — poll TCP until server ready
    │
    └── bridge.channel.send('serverReady', { port: 8000 })
```

### Phase 3: WebView

```
SillyTavernViewController detects HTTP 200
    │
    ├── webView.load(http://localhost:8000)
    ├── Wait 1s for render
    └── Fade out overlay (0.4s)
        │
        ▼
    Browser loads index.html
        ├── CSS: style.css + 20+ stylesheets
        ├── JS libs: jQuery, cropper, toastr, select2
        ├── ES modules: script.js → imports lib.js (pre-compiled)
        └── Full SillyTavern UI renders
```

---

## 6. Path Architecture

### On-device directory layout

```
/var/mobile/Containers/Data/Application/{UUID}/
├── Documents/
│   ├── st-startup.log                    ← Node.js startup log (visible in Files app)
│   └── SillyTavern/                      ← DATA_ROOT (user data)
│       ├── data/default-user/            ← Characters, chats, settings, etc.
│       ├── _webpack/                     ← (unused on iOS; webpack is stubbed)
│       └── secrets.json                  ← API keys
│
├── Library/
│   ├── Application Support/
│   │   └── st_config.json               ← Bundle paths written by AppDelegate
│   │
│   └── nodejs/                           ← nodejs-mobile sandbox
│       ├── public/                       ← Copied from bundle's nodejs-project/
│       │   ├── server-ios.js             ← Node entry point
│       │   ├── server-bundle.mjs         ← Bundled backend (~14MB)
│       │   ├── config.yaml               ← Server configuration
│       │   ├── package.json              ← Package metadata (type: module)
│       │   └── plugins/                  ← Server plugins
│       │
│       ├── builtin_modules/
│       │   └── bridge/                   ← nodejs-mobile IPC bridge
│       │
│       └── data/                         ← DATADIR (persistent Node.js data)
│
└── ...
```

### In the app bundle (read-only)

```
App.app/
├── public/                               ← Capacitor web assets + Node project
│   ├── index.html                        ← SillyTavern frontend entry
│   ├── script.js                         ← Main frontend JS (ES module)
│   ├── lib.js                            ← Pre-compiled npm libraries (webpack)
│   ├── style.css                         ← Main stylesheet
│   ├── css/, img/, lib/, scripts/        ← Frontend assets
│   ├── nodejs-project/                   ← Slim backend (copied to device)
│   │   ├── server-ios.js
│   │   ├── server-bundle.mjs
│   │   ├── config.yaml
│   │   ├── package.json
│   │   └── plugins/
│   ├── st-defaults/                      ← Default content (read from bundle)
│   │   └── default/                      ← Characters, chat templates, etc.
│   └── builtin_modules/                  ← nodejs-mobile bridge
│       └── bridge/
└── ...
```

### Path derivation in server-ios.js

```
DATADIR (set by plugin) = Library/nodejs/data/
    │
    └── path.resolve(DATADIR, '..', '..', '..')
        = /var/mobile/Containers/Data/Application/{UUID}/
        │
        ├── + 'Documents'        → documentsBase
        ├── + 'Documents/SillyTavern' → documentsDir (DATA_ROOT)
        └── + 'Library/Application Support' → appSupportDir
```

### Environment variable resolution

| Variable | iOS Value | Desktop Default |
|----------|-----------|-----------------|
| `ST_PUBLIC_DIR` | `App.app/public/` (from st_config.json) | `{serverDir}/public/` |
| `ST_SERVER_DIR` | `Library/nodejs/public/` (__dirname) | `import.meta.dirname` |
| `ST_DEFAULTS_DIR` | `App.app/public/st-defaults/` (from st_config.json) | `{serverDir}` |
| `DATADIR` | `Library/nodejs/data/` (set by plugin) | Not set |
| `NODE_PATH` | `Library/nodejs/public:Library/nodejs/builtin_modules` | Not set |

---

## 7. Skip-Copy Optimisation

### Problem

Xcode increments `CFBundleVersion` on every debug build. The nodejs-mobile plugin checks this to detect app updates and re-copies `nodejs-project/` each time — which takes 30–60s for the full file set.

### Solution

`AppDelegate.skipNodeJSCopyIfFilesExist()` short-circuits the check:

1. Compare byte sizes of `server-bundle.mjs` and `server-ios.js` between:
   - **Bundle** (`App.app/public/nodejs-project/`)
   - **Disk** (`Library/nodejs/public/`)

2. **If sizes match:** Set `UserDefaults["CapacitorNodeJS_AppUpdateTime"] = CFBundleVersion`
   → Plugin's `isAppUpdated()` returns `false` → skip copy ⚡️

3. **If sizes differ:** Delete on-disk `Library/nodejs/public/` and clear `UserDefaults`
   → Plugin detects update → full recopy 🔄

This means:
- **Debug builds with no code changes:** instant start (~1s)
- **Code changes:** size differs → forced recopy (~5s for slim dir)
- **First install:** no on-disk files → full copy

---

## 8. Xcode Build Phases

### "Inject nodejs-project" (Shell Script Build Phase)

```bash
set -e
SRC="$SRCROOT/../../nodejs-project-deploy"
DEST="$SRCROOT/App/public/nodejs-project"
if [ -d "$SRC" ]; then
  rm -rf "$DEST"
  cp -R "$SRC" "$DEST"
else
  echo "error: $SRC not found — run prepare-ios.sh first" >&2
  exit 1
fi
```

**Important:** This runs on every Xcode build. It copies from `nodejs-project-deploy/` (the slim deploy directory created by `prepare-ios.sh` Step 4). This means:
- **Any manual edits to `ios/App/App/public/nodejs-project/`** are overwritten on next build
- **Changes to `server-ios.js` must be propagated** to both `nodejs-project/` (source) and `nodejs-project-deploy/` (what Xcode reads from)
- The recommended flow: edit `nodejs-project/server-ios.js` → copy to `nodejs-project-deploy/server-ios.js` → rebuild in Xcode

---

## 9. File Reference

### Build Scripts

| File | Purpose |
|------|---------|
| `ios-app/scripts/prepare-ios.sh` | Main build script — copies sources, bundles, syncs, pre-compiles |
| `ios-app/scripts/bundle-server.mjs` | esbuild config for server bundle |
| `webpack.config.js` (repo root) | Webpack config for `lib.js` frontend bundle |

### Node.js Runtime

| File | Purpose |
|------|---------|
| `ios-app/nodejs-project/server-ios.js` | iOS entry point — logging, paths, env vars, imports bundle |
| `ios-app/nodejs-project/server-ios-entry.js` | esbuild entry — wraps server-main.js import in IIFE |
| `ios-app/nodejs-project/server-bundle.mjs` | Bundled backend (~14MB) — output of esbuild |
| `ios-app/nodejs-project/config.yaml` | Server config (ports, CSRF, auth, etc.) |
| `ios-app/nodejs-project/package.json` | Package metadata; `"type": "module"`, `"main": "server-ios.js"` |

### Swift / Xcode

| File | Purpose |
|------|---------|
| `ios-app/ios/App/App/AppDelegate.swift` | Bundle path config, skip-copy optimisation |
| `ios-app/ios/App/App/SillyTavernViewController.swift` | Loading overlay, server polling, WebView loading |
| `ios-app/ios/App/App/Info.plist` | App configuration, ATS exemptions |
| `ios-app/capacitor.config.json` | Capacitor config — server URL, nodeDir, startMode |

### Capacitor Plugin

| File | Purpose |
|------|---------|
| `node_modules/@choreruiz/capacitor-node-js/ios/Swift/NodeJS.swift` | Node.js engine — copy, start, IPC |
| `node_modules/@choreruiz/capacitor-node-js/ios/Swift/NodeJSPlugin.swift` | Capacitor bridge — auto-start, lifecycle, messaging |

### Deploy Directories

| Directory | Created by | Used by |
|-----------|-----------|---------|
| `ios-app/nodejs-project/` | Manual + prepare-ios.sh Step 1 | esbuild, reference source |
| `ios-app/nodejs-project-deploy/` | prepare-ios.sh Step 4 | Xcode build phase |
| `ios-app/ios/App/App/public/nodejs-project/` | Xcode build phase | App bundle → device |
| `dist/_webpack/{version}/output/` | prepare-ios.sh Step 4.6 | Copied to `public/lib.js` |

---

## 10. Bugs Found & Fixed

### Bug 1: Node.js crashes silently after first log line

**Symptom:** `st-startup.log` contained only the header and one log line. The app was stuck on "Starting local server…" indefinitely.

**Root cause:** `process.stderr.write(line)` in the `log()` function. On iOS/nodejs-mobile, stderr (fd 2) is a pipe with no reader. Writing to it delivers **SIGPIPE** to the process, which kills it instantly at the OS level. This is not a JavaScript exception — `try/catch` cannot intercept it, and `uncaughtException` handlers never fire.

The first `fs.appendFileSync()` in `log()` completed successfully (writing the line to the file), then `process.stderr.write()` killed the process before the next line could execute.

**Fix:** Removed `process.stderr.write()` from `log()` entirely. On iOS, stderr output goes nowhere useful (not to Xcode console, not to any log). The file log (`st-startup.log`) is the sole diagnostic mechanism.

```javascript
// Before (crashes):
function log(msg) {
    const line = `[iOS ${elapsed()}] ${msg}\n`;
    try { fs.appendFileSync(logPath, line); } catch (_) {}
    process.stderr.write(line);  // ← SIGPIPE kills process
}

// After (fixed):
function log(msg) {
    const line = `[iOS ${elapsed()}] ${msg}\n`;
    try { fs.appendFileSync(logPath, line); } catch (_) {}
}
```

### Bug 2: Crash handlers registered too late

**Symptom:** If any error occurred before the `uncaughtException` handler was registered, Node crashed silently with no diagnostic output.

**Fix:** Moved `process.on('uncaughtException')` and `process.on('unhandledRejection')` to immediately after the `log()` function is defined — before the first log call and before any other code that could throw.

### Bug 3: `console.error(someError)` logs `{}`

**Symptom:** Error objects logged via `console.error` appeared as `{}` in the log file because `JSON.stringify(new Error('...'))` returns `{}` (Error properties are non-enumerable).

**Fix:** Introduced `serializeArg()` helper that checks for `Error` instances first and extracts `.stack` or `.name: .message`:

```javascript
function serializeArg(a) {
    if (a instanceof Error) {
        return a.stack ? `${a.stack}` : `${a.name}: ${a.message}`;
    }
    if (typeof a === 'object' && a !== null) {
        try { return JSON.stringify(a); } catch (_) { return String(a); }
    }
    return String(a);
}
```

### Bug 4: `JSON.stringify` throws on circular references

**Symptom:** If a console.log argument contained circular references, `JSON.stringify` threw, crashing the console redirect.

**Fix:** Wrapped `JSON.stringify` in `try/catch` with `String()` fallback (in `serializeArg()`).

### Bug 5: `console.debug` not redirected

**Symptom:** Debug-level messages were lost — they went to the original `console.debug` (which goes nowhere on iOS) instead of the log file.

**Fix:** Added `console.debug` to the redirect list alongside `console.log`, `console.error`, and `console.warn`.

### Bug 6: Blank page after server starts

**Symptom:** Server started successfully (port 8000 open, log shows "SillyTavern is listening"), WebView loaded, but the page was completely blank with an empty browser console.

**Root cause:** `public/lib.js` bundles 21 npm packages (lodash, fuse.js, DOMPurify, highlight.js, etc.) for the browser. On desktop, the webpack-serve middleware compiles this on-the-fly. On iOS, webpack is stubbed out (`next()` passthrough), so the browser received the **raw source file** with bare specifiers like `import lodash from 'lodash'` — which browsers cannot resolve. The entire ES module import chain failed silently.

**Fix:** Added Step 4.6 to `prepare-ios.sh`: run webpack with `forceDist=true` to pre-compile `lib.js`, then copy the compiled bundle (~1.9MB) over the raw source in the Xcode public directory.

### Bug 7: Fix never reached device (Xcode build phase overwrites)

**Symptom:** Manually copying fixed `server-ios.js` to the Xcode bundle directory with `cp` had no effect — the app still ran the old version.

**Root cause:** Xcode has a "Inject nodejs-project" build phase that copies from `nodejs-project-deploy/` on every build, overwriting any manual changes to `ios/App/App/public/nodejs-project/`.

**Fix:** Changes to `server-ios.js` must be propagated to `nodejs-project-deploy/server-ios.js` (the deploy directory), not just the Xcode bundle copy. The correct flow:
1. Edit `ios-app/nodejs-project/server-ios.js`
2. Copy to `ios-app/nodejs-project-deploy/server-ios.js`
3. Rebuild in Xcode (the build phase handles the rest)

---

## 11. Known Limitations

### nodejs-mobile constraints
- **Node 18 only** — nodejs-mobile ships Node 18.20.4; no newer versions available
- **No native addons** — `.node` binary modules don't work (no C++ compilation on device)
- **No `child_process`** — `spawn`, `exec`, `fork` are unavailable in the iOS sandbox
- **No JIT** — Node runs in interpreter mode on iOS (JIT compilation is not allowed by Apple)
- **2MB thread stack** — Node.js engine requires a minimum 2MB stack (configured in plugin)

### Stubbed features
- **Git integration** — `simple-git` is stubbed; no git operations on device
- **ONNX/Transformers** — `sillytavern-transformers` unavailable; local AI features (classification, captioning, embeddings, TTS, STT) are disabled
- **System browser** — `open` is stubbed; links don't open external browser
- **Webpack** — Stubbed at runtime; must be pre-compiled at build time
- **Image processing** — WASM codecs (`@jimp/wasm-*`) may fail; core Jimp still works for basic operations
- **Token counting** — `tiktoken` native module unavailable; falls back to approximate counting

### Bridge / IPC
- `import('bridge')` may fail if `builtin_modules/` was not properly copied to `Library/nodejs/builtin_modules/`
- If bridge fails, the `serverReady` event is not sent to Swift — but the polling mechanism in `SillyTavernViewController` detects the server via HTTP anyway
- NODE_PATH is set to `projectPath:modulesPath` by the plugin — but ESM `import()` may not respect NODE_PATH (it's a CJS mechanism)

### Performance
- First launch is slow (~1–3 minutes): nodejs-mobile parses the 14MB bundle in interpreter mode AND initialises default user data
- Subsequent launches: ~1–5s depending on skip-copy optimisation
- Memory: the Node.js process + V8 heap uses ~100–200MB; iOS may kill the app under memory pressure
