# SillyTavern for iOS — Run SillyTavern on iPhone & iPad

> A fork of [SillyTavern](https://github.com/SillyTavern/SillyTavern) with a full native iOS port — runs the complete SillyTavern backend **on-device**, no server required. Use SillyTavern on your iPhone or iPad without a PC, a VPN, or a remote server.

[![iOS 15+](https://img.shields.io/badge/iOS-15%2B-blue?logo=apple)](ios-app/)
[![Node.js 18](https://img.shields.io/badge/Node.js-18-green?logo=node.js)](ios-app/nodejs-project/)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%203.0-orange)](LICENSE)

---

## What is SillyTavern for iOS?

**SillyTavern for iOS** lets you run the full SillyTavern experience natively on your **iPhone or iPad** — no Mac staying on, no external server, no cloud. The complete Node.js backend runs entirely on-device using [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile).

This is the only open-source iOS port of SillyTavern that runs the **full backend on-device**. Connect to any remote LLM API (OpenAI, Claude, OpenRouter, Kobold, etc.) directly from your iPhone.

**Supported devices:** iPhone and iPad  
**Minimum iOS:** 15.0  
**SillyTavern version:** currently 1.16

---

## Why use this instead of other options?

| | SillyTavern for iOS | Browser (remote server) | Other iOS apps |
|---|---|---|---|
| Full SillyTavern UI | ✅ | ✅ | ❌ |
| Runs on-device | ✅ | ❌ | varies |
| No server needed | ✅ | ❌ | ✅ |
| Open source | ✅ | — | rarely |
| Character cards & lorebooks | ✅ | ✅ | ❌ |
| Free | ✅ | depends | often paid |

---

## Features

- ✅ Full SillyTavern experience on iOS — same UI as desktop
- ✅ Runs entirely on-device — no external server, no Wi-Fi dependency
- ✅ Character cards, lorebooks, presets — everything syncs to your Files app
- ✅ Data persists in Files app → SillyTavern folder (accessible outside the app)
- ✅ Works with any remote LLM API: OpenAI, Anthropic Claude, OpenRouter, KoboldAI, Ollama...
- ⚠️ No JIT (Apple restriction) — slower than desktop, but fully functional
- ⚠️ No local AI models (no transformers, captioning, TTS/STT)
- ⚠️ No Extension support
- ⚠️ Sliders don't work
- ⚠️ First start may not launch — force restart may be required
- ⚠️ Many other known issues

---

## Installing SillyTavern on iPhone or iPad

> You will need a Mac, Xcode, and an Apple ID (free) to sideload.  
> An IPA will be distributed later for use with SideStore, AltStore, or Sideloadly.

### Prerequisites

- macOS with Xcode 15+
- iPhone or iPad running iOS 15+
- Apple ID (free account works)

### Quick install

```bash
# 1. Clone this repo
git clone https://github.com/elouannd/SillyTavern-iOS.git
cd SillyTavern-iOS/ios-app

# 2. Install dependencies and build the iOS bundle
npm install
bash scripts/prepare-ios.sh

# 3. Open in Xcode
open ios/App/App.xcodeproj
```

Then in Xcode:
1. Select your device in the toolbar
2. Go to **Signing & Capabilities** → set your Team to your Apple ID
3. Hit **Run** (▶)

**First launch is slow** — Node.js parses a 14MB bundle without JIT. Budget 1–3 minutes. Subsequent launches are fast (~1–2s).

---

## Frequently Asked Questions

**Can I use SillyTavern on iPhone without a computer running?**  
Yes — that's the whole point of this port. The Node.js server runs directly on your iPhone using nodejs-mobile. No PC or Mac needs to stay on.

**Does it support local AI models on iPhone?**  
Not yet. Local model inference (transformers, llama.cpp, etc.) is blocked by Apple's no-JIT policy. You can still connect to any remote API like OpenRouter, OpenAI, or a home server.

**Is this available on the App Store?**  
No. Due to Apple's policies on sideloading and AI apps, this must be sideloaded via Xcode or AltStore/SideStore. An IPA release is planned.

**What LLM APIs work with this?**  
Any API supported by SillyTavern works: OpenAI, Anthropic Claude, OpenRouter, KoboldAI, TabbyAPI, Ollama (remote), and more.

**Is this different from NativeTavern or MiniTavern?**  
Yes. This is a direct port of the full upstream SillyTavern codebase, running the actual Node.js backend on-device. It is not a rewrite or a simplified client.

**What iOS version do I need?**  
iOS 15.0 or later.

---

## For Developers — Project Structure

```
SillyTavern-iOS/
├── src/                        ← SillyTavern backend (upstream)
├── public/                     ← SillyTavern frontend (upstream)
│   ├── scripts/ios-init.js     ← iOS-specific frontend init
│   └── css/ios-overrides.css   ← iOS layout fixes
└── ios-app/
    ├── nodejs-project/         ← Node.js project copied to device
    │   ├── server-ios.js       ← iOS entry point (replaces server.js)
    │   └── server-ios-entry.js ← esbuild entry shim
    ├── nodejs-project-deploy/  ← What Xcode copies to the bundle
    ├── scripts/
    │   ├── prepare-ios.sh      ← Full build pipeline
    │   └── bundle-server.mjs   ← esbuild config
    └── ios/App/App/
        ├── AppDelegate.swift               ← Bundle path config
        └── SillyTavernViewController.swift ← Loading overlay + polling
```

### How it works

1. **`prepare-ios.sh`** bundles the SillyTavern backend with esbuild into `server-bundle.mjs` (~14MB) and pre-builds `lib.js` with webpack
2. **Xcode** copies everything into the app bundle
3. **On launch**, `AppDelegate` writes bundle paths to `st_config.json`
4. **nodejs-mobile** starts `server-ios.js` which imports `server-bundle.mjs`
5. **SillyTavernViewController** polls `localhost:8000` and loads the WebView when the server is ready

### Building after upstream updates

```bash
cd ios-app
npm install          # if dependencies changed
bash scripts/prepare-ios.sh
# Then rebuild in Xcode
```

### Key technical notes

- **SIGPIPE**: `process.stdout.write` and `process.stderr.write` are replaced with no-ops — nodejs-mobile's pipes have no reader and any write triggers SIGPIPE
- **No ICU**: `Intl` is polyfilled in `server-ios.js` since nodejs-mobile has no ICU data
- **No webpack at runtime**: `public/lib.js` must be pre-built (done by `prepare-ios.sh`)
- **Xcode overwrites**: Always edit `nodejs-project/server-ios.js` and sync to `nodejs-project-deploy/` — Xcode reads from there

See [ios-app/IOS-PORT.md](ios-app/IOS-PORT.md) for full technical documentation.

---

## Upstream SillyTavern

This repo tracks [SillyTavern/SillyTavern](https://github.com/SillyTavern/SillyTavern). All original features and documentation apply.

- **Docs:** <https://docs.sillytavern.app/>
- **Discord:** <https://discord.gg/sillytavern>
- **Reddit:** <https://reddit.com/r/SillyTavernAI>

---

## License

AGPL-3.0 — see [LICENSE](LICENSE)

iOS port additions are also AGPL-3.0.
