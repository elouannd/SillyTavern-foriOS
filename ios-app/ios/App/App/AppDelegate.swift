import UIKit
import Capacitor

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        writeBundlePathConfig()
        skipNodeJSCopyIfFilesExist()
        return true
    }

    // ── Write bundle path for Node.js ─────────────────────────────────────────
    // Node.js can't call Bundle.main, so AppDelegate writes the bundle's public/
    // path to Application Support before Node starts. server-ios.js reads this
    // to set ST_PUBLIC_DIR and ST_SERVER_DIR, avoiding the need to copy the
    // 26MB frontend and 16MB defaults into the nodejs-project on device.
    private func writeBundlePathConfig() {
        let bundlePublicPath = Bundle.main.bundlePath + "/public"
        let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        try? FileManager.default.createDirectory(atPath: appSupport, withIntermediateDirectories: true)
        let configPath = (appSupport as NSString).appendingPathComponent("st_config.json")
        // bundleServerRoot points at st-defaults/ which contains default/ for content init.
        let bundleServerRoot = bundlePublicPath + "/st-defaults"
        let config: [String: String] = [
            "bundlePublicPath": bundlePublicPath,
            "bundleServerRoot": bundleServerRoot,
            "documentsPath": documentsPath
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            try? data.write(to: URL(fileURLWithPath: configPath))
            NSLog("[ST-Swift] 📍 Bundle public: \(bundlePublicPath), server root: \(bundleServerRoot)")
        }
    }

    // ── Skip redundant nodejs-project copy ────────────────────────────────────
    // The @choreruiz/capacitor-node-js plugin re-copies the entire nodejs-project
    // whenever CFBundleVersion changes — which Xcode does on every debug build.
    // Fix: if the files already exist on disk and BOTH server-bundle.mjs AND
    // server-ios.js sizes match the bundle, skip the copy.
    private func skipNodeJSCopyIfFilesExist() {
        let library = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true).first!
        let projectPath = (library as NSString).appendingPathComponent("nodejs/public")

        if FileManager.default.fileExists(atPath: projectPath) {
            let bundleDir = "public/nodejs-project"
            let bundleBundle = Bundle.main.path(forResource: "server-bundle", ofType: "mjs", inDirectory: bundleDir)
            let bundleEntry = Bundle.main.path(forResource: "server-ios", ofType: "js", inDirectory: bundleDir)

            let diskBundle = (projectPath as NSString).appendingPathComponent("server-bundle.mjs")
            let diskEntry  = (projectPath as NSString).appendingPathComponent("server-ios.js")

            let sz = { (p: String?) -> Int in
                guard let p = p else { return 0 }
                return (try? FileManager.default.attributesOfItem(atPath: p))?[.size] as? Int ?? 0
            }

            let bundleBundleSz = sz(bundleBundle); let diskBundleSz = sz(diskBundle)
            let bundleEntrySz  = sz(bundleEntry);  let diskEntrySz  = sz(diskEntry)

            NSLog("[ST-Swift] 📏 nodejs-project sizes — bundle: server-bundle=%d, server-ios=%d | disk: server-bundle=%d, server-ios=%d",
                  bundleBundleSz, bundleEntrySz, diskBundleSz, diskEntrySz)

            if bundleBundleSz > 0 && bundleBundleSz == diskBundleSz
               && bundleEntrySz > 0 && bundleEntrySz == diskEntrySz {
                let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
                UserDefaults.standard.set(currentVersion, forKey: "CapacitorNodeJS_AppUpdateTime")
                NSLog("[ST-Swift] ⚡️ nodejs-project up to date (bundle=%d, entry=%d bytes) — skipping copy",
                      bundleBundleSz, bundleEntrySz)
            } else {
                NSLog("[ST-Swift] 🔄 files changed (bundle=%d vs %d, entry=%d vs %d) — forcing recopy",
                      bundleBundleSz, diskBundleSz, bundleEntrySz, diskEntrySz)
                // Remove BOTH the on-disk project AND the update time to force plugin recopy
                try? FileManager.default.removeItem(atPath: projectPath)
                UserDefaults.standard.removeObject(forKey: "CapacitorNodeJS_AppUpdateTime")
            }
        } else {
            NSLog("[ST-Swift] 📦 First install — nodejs-project will be copied now (~30-60s)")
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}
    func applicationDidBecomeActive(_ application: UIApplication) {}
    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}
