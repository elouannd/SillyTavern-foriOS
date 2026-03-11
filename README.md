# SillyTavern for iOS

> ⚠️ **Preliminary / experimental port** — This is an early test of SillyTavern running natively on iOS and iPadOS. Expect bugs.

Works on **iPhone** and **iPad** (iOS 15+). Runs the full SillyTavern backend on-device via [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile) — no external server needed.

---

## Known Issues

<!-- Add issues here -->

---

## How to Build

```bash
git clone https://github.com/elouannd/SillyTavern-iOS.git
cd SillyTavern-iOS/ios-app
npm install
bash scripts/prepare-ios.sh
open ios/App/App.xcodeproj
```

In Xcode: select your device → **Signing & Capabilities** → set your Team → hit **Run** ▶

> First launch can take 1–3 minutes while the app initialises.

## How to Update (upstream SillyTavern)

```bash
git fetch upstream
git merge upstream/release
cd ios-app && bash scripts/prepare-ios.sh
# Rebuild in Xcode
```

---

## License

AGPL-3.0 — see [LICENSE](LICENSE)

