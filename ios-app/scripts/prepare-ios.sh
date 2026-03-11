#!/usr/bin/env bash
# prepare-ios.sh
# Prepares the SillyTavern backend for inclusion in the iOS Capacitor build.
#
# Run this script from the ios-app/ directory before `npx cap sync` or Xcode build.
# It:
#   1. Copies SillyTavern backend source (src/, default/) into nodejs-project/
#   2. Installs production npm dependencies in nodejs-project/
#   3. Runs `npx cap sync` to copy web assets + update iOS Xcode project
#   4. Copies the nodejs-project into the Xcode project's public folder
#   5. Copies the nodejs-mobile builtin_modules bridge files
#
# Requirements: Node.js 18+, npm, Xcode Command Line Tools, CocoaPods

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$IOS_APP_DIR")"
NODEJS_PROJECT="$IOS_APP_DIR/nodejs-project"
XCODE_PUBLIC="$IOS_APP_DIR/ios/App/App/public"
PLUGIN_DIR="$IOS_APP_DIR/node_modules/@choreruiz/capacitor-node-js"

echo "🍎 SillyTavern iOS — prepare script"
echo "   Repo root:       $REPO_ROOT"
echo "   ios-app dir:     $IOS_APP_DIR"
echo "   nodejs-project:  $NODEJS_PROJECT"
echo "   Xcode public:    $XCODE_PUBLIC"
echo ""

# ── Step 1: Copy backend source into nodejs-project ──────────────────────────
echo "📦 Step 1: Syncing backend source files..."

# src/ — all server endpoint logic
echo "   Copying src/..."
rm -rf "$NODEJS_PROJECT/src"
cp -R "$REPO_ROOT/src" "$NODEJS_PROJECT/src"

# default/ — default config and content templates
echo "   Copying default/..."
rm -rf "$NODEJS_PROJECT/default"
cp -R "$REPO_ROOT/default" "$NODEJS_PROJECT/default"

# plugins/ — plugin directory (may be empty, but needed for directory structure)
echo "   Copying plugins/..."
rm -rf "$NODEJS_PROJECT/plugins"
cp -R "$REPO_ROOT/plugins" "$NODEJS_PROJECT/plugins"

# post-install.js — used during startup checks
echo "   Copying post-install.js..."
cp "$REPO_ROOT/post-install.js" "$NODEJS_PROJECT/post-install.js"

# server.js / server-ios-entry.js — root entry points
echo "   Copying server.js and server-ios-entry.js..."
cp "$REPO_ROOT/server.js" "$NODEJS_PROJECT/server.js"
# server-ios-entry.js lives in nodejs-project already (iOS-specific, not in repo root)

echo "   ✅ Backend source synced"
echo ""

# ── Step 2: Install production dependencies ───────────────────────────────────
echo "📦 Step 2: Installing production dependencies (Node 18 target)..."
echo "   This may take a few minutes..."
echo "   (sillytavern-transformers is intentionally excluded)"
echo ""

cd "$NODEJS_PROJECT"
npm install --omit=dev --engine-strict=false 2>&1 | tail -5

echo "   ✅ Dependencies installed"
echo ""

# ── Step 2.5: Bundle server code with esbuild ────────────────────────────────
echo "📦 Step 2.5: Bundling server with esbuild..."
echo "   (Produces one ~16MB file instead of 11,902 node_modules files)"
echo "   (The plugin copies nodejs-project on every launch — fewer files = faster start)"
echo ""

cd "$IOS_APP_DIR"
node scripts/bundle-server.mjs

echo ""

DEPLOY="$IOS_APP_DIR/nodejs-project-deploy"

# ── Step 4: Build slim deploy directory ──────────────────────────────────────
# We keep only files needed at runtime. node_modules and src/ are excluded —
# they're inlined into server-bundle.mjs by esbuild.
# This slim directory is what the plugin copies on every launch.
echo "📁 Step 4: Building slim deploy directory..."

rm -rf "$DEPLOY"
mkdir -p "$DEPLOY"

# Runtime files needed on-device (NO default/ or public/ — those are read from the bundle)
# default/ → read from App.app/public/nodejs-project/default/ (ST_SERVER_DIR in bundle)
# public/  → read from App.app/public/            (ST_PUBLIC_DIR in bundle)
# This reduces the on-device copy from ~55MB to ~15MB.
cp "$NODEJS_PROJECT/server-ios.js"       "$DEPLOY/server-ios.js"
cp "$NODEJS_PROJECT/server-bundle.mjs"   "$DEPLOY/server-bundle.mjs"
cp "$NODEJS_PROJECT/config.yaml"         "$DEPLOY/config.yaml"
cp "$NODEJS_PROJECT/package.json"        "$DEPLOY/package.json"
cp -R "$NODEJS_PROJECT/plugins"          "$DEPLOY/plugins"

echo "   ✅ Slim deploy directory built"
echo ""

# ── Step 3: Patch @choreruiz/capacitor-node-js Package.swift version ─────────
# The plugin pins capacitor-swift-pm at 8.1.0 but Capacitor 8.2 requires 8.2.0.
PLUGIN_PKG="$IOS_APP_DIR/node_modules/@choreruiz/capacitor-node-js/Package.swift"
if [ -f "$PLUGIN_PKG" ]; then
    sed -i '' 's/exact: "8.1.0"/exact: "8.2.0"/g' "$PLUGIN_PKG"
    echo "   🔧 Patched @choreruiz/capacitor-node-js Package.swift → capacitor-swift-pm 8.2.0"
fi
echo ""

# ── Step 4.5: Run cap sync ────────────────────────────────────────────────────
echo "📱 Step 4.5: Running Capacitor sync (copies frontend assets to iOS project)..."
cd "$IOS_APP_DIR"
npx cap sync ios 2>&1

echo "   ✅ Capacitor sync complete"
echo ""

# ── Step 4.6: Pre-build frontend lib.js with Webpack ─────────────────────────
# SillyTavern's public/lib.js bundles npm packages (lodash, fuse.js, DOMPurify,
# etc.) for the browser.  Normally, the webpack-serve middleware compiles this
# on-the-fly, but on iOS webpack is stubbed out (no JIT compiler available).
# We pre-build the bundle here so the browser gets the compiled version.
echo "📦 Step 4.6: Pre-building frontend lib.js with Webpack..."

cd "$REPO_ROOT"
node --input-type=module -e "
import getPublicLibConfig from './webpack.config.js';
import webpack from 'webpack';
const config = getPublicLibConfig(true);
const compiler = webpack(config);
compiler.run((err, stats) => {
    if (err) { console.error(err); process.exit(1); }
    console.log(stats.toString(config.stats));
    compiler.close(() => {});
});
"

# Find the compiled lib.js and copy it over the raw source in Xcode public/
WEBPACK_LIB=$(find "$REPO_ROOT/dist/_webpack" -name "lib.js" -type f 2>/dev/null | head -1)
if [ -n "$WEBPACK_LIB" ]; then
    cp "$WEBPACK_LIB" "$XCODE_PUBLIC/lib.js"
    echo "   ✅ lib.js pre-built ($(wc -c < "$WEBPACK_LIB" | tr -d ' ') bytes)"
else
    echo "   ⚠️  Webpack build failed — lib.js not found in dist/"
    echo "      The frontend will not work without this file."
fi
cd "$IOS_APP_DIR"
echo ""

# ── Step 5: Copy slim deploy directory to Xcode public/ ──────────────────────
# This is what the plugin copies to device on first install.
# default/ and public/ are NOT included here — they're read from the bundle.
echo "📁 Step 5: Copying deploy directory to Xcode public folder..."

DEST="$XCODE_PUBLIC/nodejs-project"
rm -rf "$DEST"
cp -R "$DEPLOY" "$DEST"

echo "   ✅ nodejs-project (slim) copied to $DEST"
echo "   Size: $(du -sh "$DEST" | cut -f1)"
echo "   server-ios.js bytes: $(wc -c < "$DEST/server-ios.js" | tr -d ' ')"
echo "   server-bundle.mjs bytes: $(wc -c < "$DEST/server-bundle.mjs" | tr -d ' ')"
echo ""

# ── Step 5.5: Put default/ in a separate bundle folder (st-defaults/) ────────
# default/ stays in the bundle but OUTSIDE nodejs-project so the plugin
# never copies it to device. AppDelegate writes the bundle path to st_config.json
# and server-ios.js sets ST_SERVER_DIR = App.app/public/st-defaults/ so the
# content manager finds st-defaults/default/ for first-run data initialisation.
echo "📁 Step 5.5: Copying default/ to bundle st-defaults/ folder..."
ST_DEFAULTS="$XCODE_PUBLIC/st-defaults"
rm -rf "$ST_DEFAULTS"
mkdir -p "$ST_DEFAULTS"
cp -R "$NODEJS_PROJECT/default" "$ST_DEFAULTS/default"
echo "   ✅ st-defaults/default copied ($(du -sh "$ST_DEFAULTS" | cut -f1))"
echo ""

# ── Step 6: Copy capacitor-node-js bridge builtin_modules ────────────────────
echo "🔌 Step 6: Copying nodejs-mobile bridge modules..."

if [ -d "$PLUGIN_DIR/ios/assets/builtin_modules" ]; then
    cp -R "$PLUGIN_DIR/ios/assets/builtin_modules" "$XCODE_PUBLIC/builtin_modules"
    echo "   ✅ builtin_modules copied"
else
    echo "   ⚠️  builtin_modules not found at $PLUGIN_DIR/ios/assets/builtin_modules"
    echo "      Check that @choreruiz/capacitor-node-js is installed."
fi

echo ""
echo "✅ iOS prepare complete!"
echo ""
echo "Next steps:"
echo "  1. Open ios/App/App.xcworkspace in Xcode"
echo "  2. Set your Apple Developer Team in Signing & Capabilities"
echo "  3. Select a device or simulator and hit Build & Run"
echo ""
echo "On first launch, the app needs ~1-3s for the Node.js server to start."
